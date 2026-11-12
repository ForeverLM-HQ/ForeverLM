import Foundation

/// One record a move pass took from one zone to another (D51): its type and logical id, the zone
/// names it left and entered (`Library`, `Catalog`, `Space-<spaceID>`), and the epoch milliseconds
/// the pass copied it.
struct MoveMapMove: Hashable, Sendable {
    let type: String
    let id: String
    let from: String
    let to: String
    let at: Int64
}

enum MoveListError: Error, Equatable {
    case notAMoveList(String)
}

/// The `moveMaps` lookup (docs/cloudkit-schema-design.md §4.4, §6.2, D51), the twin of
/// `schema/js/move-maps.js`, for the write paths of the private engine and SpaceSync on the Mac and
/// the iPhone. Every SpaceMoveJob pass, every re-homing pass and every reverse move writes one entry
/// into the personal root's `ZoneRoot.moveMaps`, a FileRef to a gzip satellite (role
/// `moveMap.<key>`) listing what that pass moved. A pending write that meets `unknownItem` or
/// `zoneNotFound` asks this lookup whether its record was moved rather than deleted; if so, its
/// fields go to the copy in the zone the record lives in now (a space, or `Library` after a reverse
/// move), and the delete never wins over it.
///
/// A list's bytes are gzip of compact JSON with sorted keys, `{"v": 1, "moves": [{"type", "id",
/// "from", "to", "at"}]}`. Entries are never rewritten, so each is read once and kept; past 32 the
/// maintenance Mac folds them into `folded.<n>`, whose list holds the same moves, so every entry is
/// read the same way. Two moves of one record (a move and its reverse, a re-homing) are ordered by
/// `at`, then by entry key, then by place in the list.
final class MoveMapIndex: @unchecked Sendable {
    /// Reads one entry's stored bytes: every part of the satellite, in order.
    typealias BodyFetch = @Sendable (FileRef) async throws -> Data

    static let listVersion = 1
    /// What a list may inflate to when read: far above 32 folded entries of a large notebook.
    static let listMaxInflatedBytes = 16 * 1024 * 1024

    static func role(forKey key: String) -> String { "moveMap.\(key)" }

    private struct RecordKey: Hashable {
        let type: String
        let id: String
    }

    private struct Placed {
        let move: MoveMapMove
        let key: String
        let index: Int
    }

    private let lock = AppLock()
    private var keys: Set<String> = []
    private var byRecord: [RecordKey: [Placed]] = [:]

    init() {}

    // MARK: - Lookup

    /// Adds one entry's moves; an entry already added is not added twice.
    func add(key: String, moves: [MoveMapMove]) {
        lock.withLock {
            guard keys.insert(key).inserted else { return }
            for (index, move) in moves.enumerated() {
                let record = RecordKey(type: move.type, id: move.id)
                var held = byRecord[record] ?? []
                held.append(Placed(move: move, key: key, index: index))
                held.sort { lhs, rhs in
                    if lhs.move.at != rhs.move.at { return lhs.move.at < rhs.move.at }
                    if lhs.key != rhs.key { return lhs.key < rhs.key }
                    return lhs.index < rhs.index
                }
                byRecord[record] = held
            }
        }
    }

    /// Whether the entry `key` was read already.
    func contains(key: String) -> Bool {
        lock.withLock { keys.contains(key) }
    }

    /// Every move of a record, in order.
    func moves(type: String, id: String) -> [MoveMapMove] {
        lock.withLock { (byRecord[RecordKey(type: type, id: id)] ?? []).map(\.move) }
    }

    /// Where a pending write aimed at the record in `zone` belongs now: the zone its latest move took
    /// it to, when a move ever took it out of `zone` and the latest did not bring it back there. Nil
    /// when it never left `zone` (its absence there is a deletion, and the delete wins, §6.2), or when
    /// it was moved back and is gone again.
    func retarget(type: String, id: String, from zone: String) -> String? {
        lock.withLock {
            let moves = byRecord[RecordKey(type: type, id: id)] ?? []
            guard moves.contains(where: { $0.move.from == zone }), let latest = moves.last else { return nil }
            return latest.move.to == zone ? nil : latest.move.to
        }
    }

    /// Whether a parent a late child names counts as present (§4.4, §5.7): some move lists it.
    func moved(type: String, id: String) -> Bool {
        lock.withLock { byRecord[RecordKey(type: type, id: id)] != nil }
    }

    // MARK: - Reading the root's entries

    /// The entries a personal root names, sorted by key; a key a fold cleared (`null`) names none.
    static func entries(of root: SyncEnvelope) -> [(key: String, file: FileRef)] {
        guard let entries = root.fields["moveMaps"]?.objectValue else { return [] }
        return entries.keys.sorted().compactMap { key in
            FileRef(json: entries[key] ?? .null).map { (key: key, file: $0) }
        }
    }

    /// Reads every entry of `root` not read yet. An entry whose body cannot be fetched is left for the
    /// next refresh; one that is not a move list this build reads is skipped and logged by the caller
    /// through the returned keys. Returns the keys it could not read.
    @discardableResult
    func refresh(from root: SyncEnvelope, fetch: BodyFetch) async -> [String] {
        var unread: [String] = []
        for (key, file) in Self.entries(of: root) where !contains(key: key) {
            do {
                add(key: key, moves: try Self.decodeList(try await fetch(file)))
            } catch {
                unread.append(key)
            }
        }
        return unread
    }

    // MARK: - The list's bytes

    static func isValid(_ move: MoveMapMove) -> Bool {
        !move.type.isEmpty && !move.id.isEmpty && SyncZoneName(move.from) != nil && SyncZoneName(move.to) != nil
            && move.from != move.to && move.at >= 0 && move.at < 9_007_199_254_740_992
    }

    /// A list's stored bytes: gzip of compact JSON with sorted keys.
    static func encodeList(_ moves: [MoveMapMove]) throws -> Data {
        guard moves.allSatisfy(isValid) else { throw MoveListError.notAMoveList("a move needs type, id, two different zones and at") }
        let json: SyncJSON = .object([
            "v": SyncJSON(listVersion),
            "moves": .array(moves.map {
                .object(["type": .string($0.type), "id": .string($0.id), "from": .string($0.from), "to": .string($0.to), "at": SyncJSON($0.at)])
            }),
        ])
        return try SyncGzip.compress(json.serialized())
    }

    /// The moves a list's stored bytes hold. A list of another version, or bytes that are not a list,
    /// throw; a move this build cannot read inside a readable list is skipped, never guessed at.
    static func decodeList(_ stored: Data) throws -> [MoveMapMove] {
        let json: SyncJSON
        do {
            json = try SyncJSON(parsing: try SyncGzip.decompress(stored, maxBytes: listMaxInflatedBytes))
        } catch {
            throw MoveListError.notAMoveList("not gzip JSON")
        }
        guard json.objectValue != nil else { throw MoveListError.notAMoveList("not an object") }
        guard json["v"]?.intValue == listVersion else { throw MoveListError.notAMoveList("version") }
        guard let moves = json["moves"]?.arrayValue else { throw MoveListError.notAMoveList("no moves") }
        return moves.compactMap { value in
            guard let type = value["type"]?.stringValue, let id = value["id"]?.stringValue,
                  let from = value["from"]?.stringValue, let to = value["to"]?.stringValue,
                  let number = value["at"]?.numberValue, number.rounded() == number
            else { return nil }
            let move = MoveMapMove(type: type, id: id, from: from, to: to, at: Int64(exactly: number) ?? -1)
            return isValid(move) ? move : nil
        }
    }

    /// Reads the moves the replica's personal root lists, fetching their bodies through `transport`.
    /// Nothing happens when the replica holds no root, or a root without its salt.
    func refreshFromPersonalRoot(store: PrivateSyncLocalStore, transport: CloudTransport) async throws {
        guard let (root, salt) = try await store.perform({ state -> (SyncEnvelope, Data)? in
            guard let root = try state.replica.personalRoot()?.envelope,
                  let salt = root.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
            else { return nil }
            return (root, salt)
        }) else { return }
        await refresh(from: root, fetch: Self.transportFetch(transport, salt: salt))
    }

    /// Reads a FileRef's parts from the private `Content` zone by name through `transport`, named with
    /// the personal library's salt: the inline `data` of each part, or its downloaded `asset`, each
    /// checked against its part hash.
    static func transportFetch(_ transport: CloudTransport, salt: Data) -> BodyFetch {
        { file in
            let zone = CloudZoneID(SyncZone.content.rawValue)
            let ids = file.parts.map {
                CloudRecordID(
                    RecordNaming.recordName(type: .content, id: SyncIdentity.contentID(owner: file.owner, role: file.role, partHash32: $0), salt: salt),
                    in: zone
                )
            }
            let results = try await transport.records(ids, in: .private, desiredKeys: [CloudRecord.dataKey, CloudRecord.assetKey])
            var body = Data()
            for (id, partHash) in zip(ids, file.parts) {
                guard let result = results[id] else { throw CloudError(.unknownItem, message: "no part \(id.recordName)") }
                let record = try result.get()
                let part: Data
                switch (record.encryptedFields[CloudRecord.dataKey], record.fields[CloudRecord.assetKey]) {
                case (.bytes(let data)?, _): part = data
                case (_, .asset(let url)?): part = try Data(contentsOf: url)
                default: throw CloudError(.unknownItem, message: "part \(id.recordName) holds no bytes")
                }
                guard FileRef.partHash32(part) == partHash else { throw CloudError(.invalidArguments, message: "part \(id.recordName) has other bytes") }
                body.append(part)
            }
            return body
        }
    }
}
