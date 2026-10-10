import CryptoKit
import Foundation

/// Every projection a build runs (docs/cloudkit-schema-design.md §14.1), by record type and by local
/// table. The trigger installer generates its triggers from the registry's tables, the feeder routes
/// outbox rows to records through it, and an inbound apply finds each record's projection in it. A
/// table read by more than one projection (`review_exchanges` feeds its Exchange and the rating's
/// Mark) gets one set of triggers, over every column any of them reads.
struct ProjectionRegistry: Sendable {
    let projections: [any RecordProjection]

    init(_ projections: [any RecordProjection]) {
        var seen = Set<SyncRecordType>()
        for projection in projections {
            precondition(seen.insert(projection.recordType).inserted, "two projections of \(projection.recordType.rawValue)")
        }
        self.projections = projections
        for name in tableNames {
            let keys = Set(readers(of: name).map(\.table.localKey))
            precondition(keys.count == 1, "\(name) is declared with two primary keys")
        }
    }

    func projection(for type: SyncRecordType) -> (any RecordProjection)? {
        projections.first { $0.recordType == type }
    }

    /// Every declaration of `table`, with the projection that reads it.
    func readers(of table: String) -> [(projection: any RecordProjection, table: ProjectedTable)] {
        projections.flatMap { projection in
            projection.tables.filter { $0.name == table }.map { (projection: projection, table: $0) }
        }
    }

    /// Every table any projection reads, sorted.
    var tableNames: [String] {
        Array(Set(projections.flatMap { $0.tables.map(\.name) })).sorted()
    }

    /// One table's declarations merged, as its triggers watch it.
    func merged(_ table: String) -> MergedProjectedTable? {
        let declarations = readers(of: table).map(\.table)
        guard let first = declarations.first else { return nil }
        func union(_ lists: [[String]]) -> [String] {
            var columns: [String] = []
            for column in lists.joined() where !columns.contains(column) { columns.append(column) }
            return columns
        }
        let keys = union([first.localKey] + declarations.map(\.keyColumns))
        return MergedProjectedTable(
            name: table,
            localKey: first.localKey,
            keyColumns: keys,
            valueColumns: union(declarations.map(\.syncedColumns)).filter { !keys.contains($0) },
            routingColumns: union(declarations.map(\.routingColumns)),
            declarations: declarations
        )
    }

    var mergedTables: [MergedProjectedTable] {
        tableNames.compactMap(merged)
    }
}

/// A table as its triggers watch it: the union of what every projection reading it declares.
struct MergedProjectedTable: Sendable {
    let name: String
    let localKey: [String]
    /// Columns whose change moves a row to another record: every declaration's key columns, and the
    /// primary key.
    let keyColumns: [String]
    /// The other columns some projection reads.
    let valueColumns: [String]
    /// What `record_key_json` holds for a removed row.
    let routingColumns: [String]
    let declarations: [ProjectedTable]
}

extension ProjectionRegistry {
    /// sha256 of `text`, as the installer records `trigger_hash`.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
