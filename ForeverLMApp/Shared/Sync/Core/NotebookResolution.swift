import Foundation

/// A zone by name (§2.2): `Library`, `Catalog`, `Content`, or `Space-<spaceID>`.
enum SyncZoneName: Hashable, Sendable, CustomStringConvertible {
    case library
    case catalog
    case content
    case space(String)

    init?(_ name: String) {
        switch name {
        case SyncZone.library.rawValue: self = .library
        case SyncZone.catalog.rawValue: self = .catalog
        case SyncZone.content.rawValue: self = .content
        default:
            guard name.hasPrefix(SyncSchema.spaceZonePrefix), name.count > SyncSchema.spaceZonePrefix.count else { return nil }
            self = .space(String(name.dropFirst(SyncSchema.spaceZonePrefix.count)))
        }
    }

    var name: String {
        switch self {
        case .library: return SyncZone.library.rawValue
        case .catalog: return SyncZone.catalog.rawValue
        case .content: return SyncZone.content.rawValue
        case .space(let spaceID): return SyncSchema.spaceZonePrefix + spaceID
        }
    }

    var kind: SyncZone {
        switch self {
        case .library: return .library
        case .catalog: return .catalog
        case .content: return .content
        case .space: return .space
        }
    }

    var isSpace: Bool { kind == .space }
    var description: String { name }
}

/// A record by its zone and logical id.
struct SyncRecordLocation: Hashable, Sendable {
    let zone: SyncZoneName
    let id: String
}

/// A notebook's redirect fields as one zone holds them.
struct NotebookRedirects: Equatable, Sendable {
    /// Merged into another notebook of the same zone (§5.2; an emptying split's parent too, D48).
    var mergedInto: String?
    /// Moved into a space: the notebook keeps its id in `Space-<movedTo>` (§5.3).
    var movedTo: String?
    /// Still moving into a space: never followed, since the space copy may not exist yet (§4.4).
    var movingTo: String?

    init(mergedInto: String? = nil, movedTo: String? = nil, movingTo: String? = nil) {
        self.mergedInto = mergedInto
        self.movedTo = movedTo
        self.movingTo = movingTo
    }
}

/// `resolveNotebook()` (§5.2): where a notebook id leads after merges, emptying splits and moves
/// into spaces, so a child that names a merged or moved notebook lands in the survivor or the space.
/// Every client runs this one walk (JS `schema/js/resolve.js`); vectors `schema/vectors/resolve.json`.
enum NotebookResolution {
    /// From `start`, up to 8 times: take the current notebook's `mergedInto` (same zone), else its
    /// `movedTo` (same id in the space's zone); stop when there is none, when the next notebook is not
    /// held, or when it was already visited. Returns the last notebook reached, or `start` itself when
    /// it is not held. `redirects` is nil for a notebook the client does not hold in that zone.
    static func resolve(_ start: SyncRecordLocation, redirects: (SyncRecordLocation) -> NotebookRedirects?) -> SyncRecordLocation {
        var current = start
        var visited: Set<SyncRecordLocation> = [start]
        for _ in 0..<SyncSchema.Limits.redirectMaxHops {
            guard let links = redirects(current) else { break }
            let next: SyncRecordLocation
            if let target = links.mergedInto, !target.isEmpty {
                next = SyncRecordLocation(zone: current.zone, id: target)
            } else if let spaceID = links.movedTo, !spaceID.isEmpty {
                next = SyncRecordLocation(zone: .space(spaceID), id: current.id)
            } else {
                break
            }
            guard redirects(next) != nil, visited.insert(next).inserted else { break }
            current = next
        }
        return current
    }
}
