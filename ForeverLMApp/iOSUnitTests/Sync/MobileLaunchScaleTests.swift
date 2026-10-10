import Foundation
import Testing
@testable import ForeverLM

/// A launch at ten times today's library (docs/cloudkit-schema-design.md D33, §11.1, §11.4, review
/// PD-24): about 72k `Library` records, 54k `Catalog` records and a 3.4k-record team space, written
/// straight into a replica file with their index rows. Opening it, loading the structure and the
/// first page of every list reads the index alone: no record is decoded but the space's root and
/// the one page of exchanges a chat shows.
@Suite("iPhone launch at 10x", .serialized)
struct MobileLaunchScaleTests {
    static let library = "private/Library"
    static let catalog = "private/Catalog"
    static let catalogKey = catalog
    static let space = "shared/alice/Space-s1"

    /// Rows of one type: `count` records named `<prefix><i>` in `zoneKey`, every payload the same small
    /// envelope, and, for an indexed type, its index row from `columns` (SQL over `i`).
    struct Bulk {
        let type: SyncRecordType
        let zoneKey: String
        let prefix: String
        let count: Int
        let columns: [String: String]
    }

    static let notebooks = 150
    static let chats = 3_350

    static let bulks: [Bulk] = [
        Bulk(type: .notebook, zoneKey: library, prefix: "nb", count: notebooks, columns: [
            "title": "'Notebook ' || i", "status": "'active'", "created_at": "i", "edited_at": "1000 + i", "has_cover": "i % 2",
        ]),
        Bulk(type: .goal, zoneKey: library, prefix: "gl", count: 200, columns: ["title": "'Goal ' || i", "status": "'active'"]),
        Bulk(type: .entry, zoneKey: library, prefix: "en", count: 5_510, columns: [
            "container_kind": "'notebook'", "container_id": "'nb' || (i % \(notebooks))", "item_kind": "'source'", "item_id": "'src' || i",
            "state": "'active'", "order_key": "printf('a%06d', i)", "origin": "'added'", "added_at": "i",
            "state_stamp": "'L1759400000000.0000.otheraaa'",
        ]),
        Bulk(type: .course, zoneKey: library, prefix: "crs", count: 60, columns: ["title": "'Course ' || i", "status": "'active'", "created_at": "i"]),
        // A course lives in no notebook; a notebook follows one by an Entry (nb7, whose page is read, follows none).
        Bulk(type: .entry, zoneKey: library, prefix: "en:follow:crs", count: 60, columns: [
            "container_kind": "'notebook'", "container_id": "'nb' || (90 + i)", "item_kind": "'course'", "item_id": "'crs' || i",
            "state": "'active'", "order_key": "printf('z%04d', i)", "origin": "'added'", "added_at": "i",
            "state_stamp": "'L1759400000000.0000.otheraaa'",
        ]),
        Bulk(type: .lesson, zoneKey: library, prefix: "les", count: 880, columns: [
            "course_id": "'crs' || (i % 60)", "order_key": "printf('a%04d', i)", "kind": "'lecture'", "title": "'Lesson ' || i",
        ]),
        Bulk(type: .quiz, zoneKey: library, prefix: "qz", count: 250, columns: ["course_id": "'crs' || (i % 60)", "title": "'Quiz ' || i", "kind": "'practice'"]),
        Bulk(type: .chat, zoneKey: library, prefix: "ch", count: chats, columns: [
            "kind": "CASE i % 3 WHEN 0 THEN 'review' ELSE 'chat' END", "notebook_id": "'nb' || (i % \(notebooks))", "title": "'Chat ' || i",
            "status": "'active'", "created_at": "i", "edited_at": "i",
        ]),
        Bulk(type: .exchange, zoneKey: library, prefix: "x", count: 16_760, columns: [
            "chat_id": "'ch' || (i % \(chats))", "seq": "i / \(chats) + 1", "created_at": "i",
        ]),
        Bulk(type: .artifact, zoneKey: library, prefix: "art", count: 1_030, columns: [
            "kind": "'doc'", "title": "'Doc ' || i", "notebook_id": "'nb' || (i % \(notebooks))", "status": "'active'", "edited_at": "i",
        ]),
        Bulk(type: .highlight, zoneKey: library, prefix: "hl", count: 920, columns: [:]),
        Bulk(type: .readingState, zoneKey: library, prefix: "rs:src", count: 10_500, columns: [
            "target_kind": "'source'", "target_id": "'src' || i", "last_read_at": "i",
        ]),
        Bulk(type: .mark, zoneKey: library, prefix: "mk:provenance:src:src", count: 19_500, columns: [
            "kind": "'provenance'", "target": "'src:src' || i", "on_flag": "1", "at": "i",
        ]),
        Bulk(type: .notebookState, zoneKey: library, prefix: "ns:nb", count: 50, columns: [
            "notebook_id": "'nb' || i", "sidebar_key": "printf('a%03d', i)", "pinned": "i % 5 = 0",
        ]),
        Bulk(type: .placement, zoneKey: library, prefix: "pl:src", count: 9_800, columns: [:]),
        Bulk(type: .card, zoneKey: library, prefix: "card", count: 600, columns: ["status": "'kept'", "deck_source_id": "'src' || i", "origin": "'manual'"]),
        Bulk(type: .sitting, zoneKey: library, prefix: "sit", count: 300, columns: [:]),
        Bulk(type: .activityLog, zoneKey: library, prefix: "al:", count: 690, columns: [:]),
        Bulk(type: .setting, zoneKey: library, prefix: "setting.", count: 900, columns: ["key": "'setting.' || i", "value_json": "'true'"]),
        Bulk(type: .device, zoneKey: library, prefix: "dev:", count: 40, columns: [:]),
        Bulk(type: .idea, zoneKey: library, prefix: "idea", count: 90, columns: [:]),
        Bulk(type: .source, zoneKey: catalog, prefix: "src", count: 50_870, columns: [
            "type": "CASE i % 4 WHEN 0 THEN 'paper' WHEN 1 THEN 'video' WHEN 2 THEN 'podcast' ELSE 'article' END",
            "title": "'Source ' || i", "title_key": "'source ' || i", "authors": "'A. Author'", "status": "CASE WHEN i % 10 = 0 THEN 'archived' ELSE 'active' END",
            "ingest_state": "'ready'", "added_at": "1000000 + i", "collection_id": "'col' || (i % 2750)", "collection_order": "printf('a%06d', i)",
            "has_pdf": "i % 2",
        ]),
        Bulk(type: .collection, zoneKey: catalog, prefix: "col", count: 2_750, columns: ["kind": "'podcastShow'", "title": "'Show ' || i", "status": "'active'"]),
        Bulk(type: .entry, zoneKey: catalog, prefix: "en:pl", count: 500, columns: [
            "container_kind": "'playlist'", "container_id": "'pl' || (i % 20)", "item_kind": "'source'", "item_id": "'src' || i",
            "state": "'active'", "order_key": "printf('a%06d', i)",
        ]),
        Bulk(type: .notebook, zoneKey: space, prefix: "team-nb", count: 10, columns: ["title": "'Team notebook ' || i", "status": "'active'", "edited_at": "i"]),
        Bulk(type: .source, zoneKey: space, prefix: "src", count: 520, columns: [
            "type": "'paper'", "title": "'Team source ' || i", "title_key": "'team source ' || i", "status": "'active'", "added_at": "i", "has_pdf": "1",
        ]),
        Bulk(type: .entry, zoneKey: space, prefix: "team-en", count: 520, columns: [
            "container_kind": "'notebook'", "container_id": "'team-nb' || (i % 10)", "item_kind": "'source'", "item_id": "'src' || i",
            "state": "'active'", "order_key": "printf('a%06d', i)",
        ]),
        Bulk(type: .chat, zoneKey: space, prefix: "team-ch", count: 20, columns: ["kind": "'chat'", "notebook_id": "'team-nb' || (i % 10)", "status": "'active'"]),
        Bulk(type: .content, zoneKey: space, prefix: "ct:", count: 2_330, columns: [:]),
    ]

    /// Writes the 10x library into the replica at `path`: records and index rows by set-based SQL.
    static func writeFixture(_ replica: MobileReplica) async throws -> Int {
        let payloads = try Dictionary(uniqueKeysWithValues: Set(bulks.map(\.type)).map { type in
            (type, try MobileSyncFixture.envelope(type, "template", type == .exchange ? ["question": .string("A question")] : [:]).storedPayload())
        })
        for bulk in bulks {
            guard let table = MobileReplica.indexTable(for: bulk.type) else { continue }
            #expect(Set(bulk.columns.keys).isSubset(of: Set(table.columns.map(\.name))), "\(table.name): \(bulk.columns.keys.sorted())")
        }
        try await MobileSyncFixture.holdSpace(replica, zoneKey: space, zoneName: "Space-s1", owned: false, name: "Acme Lab")
        return try await replica.read { replica in
            let connection = replica.connection
            try connection.executeScript("BEGIN IMMEDIATE")
            var records = 0
            for bulk in bulks {
                let numbers = "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i + 1 < \(bulk.count))"
                try connection.execute("""
                    \(numbers) INSERT INTO ck_records (zone_key, record_name, record_type, wire_id, system_fields, payload, seen_pass)
                    SELECT ?, ? || i, ?, ? || i, NULL, ?, 1 FROM n
                """, [.text(bulk.zoneKey), .text("r\(bulk.type.rawValue)\(bulk.prefix)"), .text(bulk.type.rawValue), .text(bulk.prefix), .blob(payloads[bulk.type])])
                records += bulk.count
                guard let table = MobileReplica.indexTable(for: bulk.type) else { continue }
                let names = bulk.columns.keys.sorted()
                try connection.execute("""
                    \(numbers) INSERT INTO \(table.name) (zone_key, id, record_name\(names.map { ", \($0)" }.joined()))
                    SELECT ?, ? || i, ? || i\(names.map { ", \(bulk.columns[$0]!)" }.joined()) FROM n
                """, [.text(bulk.zoneKey), .text(bulk.prefix), .text("r\(bulk.type.rawValue)\(bulk.prefix)")])
            }
            try connection.executeScript("COMMIT")
            return records
        }
    }

    @Test("A 10x replica launches into its structure and first pages without decoding its records")
    func launchesWithoutDecoding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MobileLaunchScaleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent(MobileReplica.fileName).path
        let records = try await Self.writeFixture(try MobileReplica(path: path))
        #expect(records > 126_000)

        let clock = ContinuousClock()
        let started = clock.now
        let replica = try MobileReplica(path: path)
        let opened = clock.now
        let projection = MobileProjection(replica: replica)
        let structure = try await projection.loadStructure()
        let structured = clock.now
        let sources = try await projection.sources(page: .first(50))
        let byTitle = try await projection.sources(order: .title, page: .first(50))
        let notebook = try #require(structure.resolve("nb7"))
        let entries = try await projection.entries(of: notebook)
        let team = try #require(structure.notebooks.first { $0.notebookID == "team-nb3" })
        let teamEntries = try await projection.entries(of: team)
        let paged = clock.now
        #expect(replica.decodedRecords == 1, "only the space's root was decoded (\(replica.decodedRecords))")
        let exchanges = try await projection.exchanges(ofChat: "ch12", zoneKey: Self.library)
        let finished = clock.now

        #expect(structure.notebooks.count == Self.notebooks + 10)
        #expect(structure.notebooks.first { $0.notebookID == "team-nb3" }?.spaceName == "Acme Lab")
        #expect(structure.chats.count == Self.chats + 20 && structure.cards.count == 600)
        #expect(structure.notebooks.filter(\.pinned).count == 10)
        #expect(sources.count == 50 && sources.first?.id == "src50869" && byTitle.count == 50)
        #expect(entries.count == 37 && entries.allSatisfy { $0.source != nil })
        #expect(teamEntries.count == 50 && teamEntries.allSatisfy { $0.source?.zoneKey == Self.space })
        #expect(exchanges.count == 5 && replica.decodedRecords == 6, "a chat decodes the one page it shows")

        let total = started.duration(to: finished)
        print("ms: open \(started.duration(to: opened)), structure \(opened.duration(to: structured)), pages \(structured.duration(to: paged)), exchanges \(paged.duration(to: finished)), total \(total) over \(records) records")
        #expect(total < .seconds(5), "a 10x launch reads the index, it does not walk the library (\(total))")

        // The statements the lists run, as they run them: each walks an index in its order.
        let statements = [
            MobileProjection.sourcesStatement(in: Self.catalogKey, type: nil, status: "active", order: .newest, page: .first()),
            MobileProjection.sourcesStatement(in: Self.catalogKey, type: nil, status: "active", order: .title, page: .first()),
            MobileProjection.entriesStatement(of: notebook, includeRemoved: false, page: .first()),
            MobileProjection.entriesStatement(of: team, includeRemoved: false, page: .first()),
            MobileProjection.exchangesStatement(ofChat: "ch12", zoneKey: Self.library, page: .first()),
        ]
        let plans = try await replica.read { replica -> [String] in
            try statements.map { statement in
                var lines: [String] = []
                try replica.connection.query("EXPLAIN QUERY PLAN " + statement.sql, statement.parameters) { lines.append($0.text(3) ?? "") }
                return lines.joined(separator: " | ")
            }
        }
        for plan in plans {
            #expect(plan.contains("USING INDEX") || plan.contains("USING COVERING INDEX"), "\(plan)")
            #expect(!plan.contains("USE TEMP B-TREE"), "\(plan)")
        }
    }

    @Test("At 10x, the catalog's generation-2 snapshot reads the index alone (WP19b)")
    func readModelsAtScale() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MobileLaunchScaleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent(MobileReplica.fileName).path
        _ = try await Self.writeFixture(try MobileReplica(path: path))

        let replica = try MobileReplica(path: path)
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        let took = started.duration(to: clock.now)
        print("ms: read-model snapshot \(took) for \(snapshot.sources.count) sources, \(snapshot.notebooks.count) notebooks")
        #expect(replica.decodedRecords == 1, "only the space's root is decoded (\(replica.decodedRecords))")
        #expect(snapshot.sources.count == 50_870, "a team copy of a held source is listed once")
        #expect(snapshot.notebooks.count == Self.notebooks + 10)
        #expect(snapshot.notebooks.first { $0.id == "nb7" }?.sourceIDs.count == 37)
        #expect(took < .seconds(10), "the snapshot reads index rows, it decodes no record (\(took))")
    }
}
