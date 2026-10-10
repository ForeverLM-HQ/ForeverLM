import Foundation

/// What a client's replica knows about where records are, as placement reads it.
protocol ZonePlacementReplica {
    /// Every zone where the client holds a record of `type` with logical id `id`.
    func zones(holding type: SyncRecordType, id: String) -> [SyncZoneName]
    /// A notebook's redirect fields as `location`'s zone holds them; nil when it is not held there.
    func notebookRedirects(_ location: SyncRecordLocation) -> NotebookRedirects?
    /// The space whose root says it was made for record `primaryID` and is of `kind` (`ZoneRoot.primaryID`).
    func space(kind: String, primaryID: String) -> SyncZoneName?
}

/// `zoneFor(type, home)` (§4.4): the zone a record is written into, from its type's `home` in
/// `schema/cloudkit-schema.json` (`SyncTypeSpec.home`), so Swift and JS place every type by the same
/// data. Placement always uses the resolved home: a child of a merged or moved notebook goes to the
/// survivor's or the space's zone, and a child of a notebook still moving goes into the space only
/// once the replica holds the notebook's copy there. Run before every send and every re-create.
/// Vectors: `schema/vectors/placement.json`; the JS port is `schema/js/placement.js`.
enum ZonePlacement {
    /// The zone for a record of `type` with id `id` and the field values it will be sent with,
    /// written in `library`: `.library` for the personal library, or the space it is written in.
    static func zone(for type: SyncRecordType, id: String, fields: [String: SyncJSON], writtenIn library: SyncZoneName,
                     replica: ZonePlacementReplica) -> SyncZoneName {
        let spec = type.spec
        let home = spec.home
        if let rule = spec.spaceRule, !rule.allowedValues.contains(fields[rule.field]?.stringValue ?? "") {
            return .library
        }
        if home.personalIDPrefixes.contains(where: id.hasPrefix) { return .library }
        if let kind = home.primaryOfSpace, let space = replica.space(kind: kind, primaryID: id) { return space }
        switch home.rule {
        case .library:
            return .library
        case .current(let privateZone):
            return current(privateZone, library)
        case .parent(let field, let parent):
            return parentZone(parent, id: fields[field]?.stringValue, library: library, replica: replica)
        case .container(let field, let kindField, let parents):
            guard let kind = fields[kindField]?.stringValue, let parent = parents[kind] else { return current(.library, library) }
            return parentZone(parent, id: fields[field]?.stringValue, library: library, replica: replica)
        case .owner(let field, let typeField, let roleField, let privateZone):
            if let role = fields[roleField]?.stringValue, SyncSchema.personalSatelliteRoles.contains(role) {
                return zoneName(privateZone)
            }
            guard let ownerType = fields[typeField]?.stringValue.flatMap(SyncRecordType.init(rawValue:)) else {
                return current(privateZone, library)
            }
            let ownerZone = parentZone(ownerType, id: fields[field]?.stringValue, library: library, replica: replica)
            return ownerZone.isSpace ? ownerZone : zoneName(privateZone)
        }
    }

    /// The zone of the parent record `id` names: a notebook through `resolveNotebook`, any other
    /// parent where the replica holds it (first in the library the record is written in, then the
    /// personal library, then a space); with nothing known, where a new record of the parent's type
    /// written in `library` would go.
    private static func parentZone(_ parent: SyncRecordType, id: String?, library: SyncZoneName,
                                   replica: ZonePlacementReplica) -> SyncZoneName {
        guard let id, !id.isEmpty else { return unknownParentZone(parent, library) }
        if parent.spec.isPrivateOnly { return .library }
        guard let held = preferred(replica.zones(holding: parent, id: id), library: library) else {
            return unknownParentZone(parent, library)
        }
        guard parent == .notebook else { return held }
        let resolved = NotebookResolution.resolve(SyncRecordLocation(zone: held, id: id), redirects: replica.notebookRedirects)
        if let spaceID = replica.notebookRedirects(resolved)?.movingTo, !spaceID.isEmpty,
           replica.notebookRedirects(SyncRecordLocation(zone: .space(spaceID), id: resolved.id)) != nil {
            return .space(spaceID)
        }
        return resolved.zone
    }

    private static func unknownParentZone(_ parent: SyncRecordType, _ library: SyncZoneName) -> SyncZoneName {
        switch parent.spec.home.rule {
        case .library: return .library
        case .current(let privateZone): return current(privateZone, library)
        case .parent(_, let grandparent): return unknownParentZone(grandparent, library)
        case .container, .owner: return current(.library, library)
        }
    }

    private static func preferred(_ zones: [SyncZoneName], library: SyncZoneName) -> SyncZoneName? {
        let personal: Set<SyncZoneName> = [.library, .catalog]
        if library.isSpace, zones.contains(library) { return library }
        if let zone = zones.first(where: personal.contains) { return zone }
        return zones.filter(\.isSpace).min { $0.name < $1.name }
    }

    private static func current(_ privateZone: SyncZone, _ library: SyncZoneName) -> SyncZoneName {
        library.isSpace ? library : zoneName(privateZone)
    }

    private static func zoneName(_ zone: SyncZone) -> SyncZoneName {
        switch zone {
        case .library: return .library
        case .catalog: return .catalog
        case .content: return .content
        case .space: preconditionFailure("a private zone is never Space")
        }
    }
}
