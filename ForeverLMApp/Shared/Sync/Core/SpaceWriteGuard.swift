import Foundation

/// The rules for writing into a shared space (§9.2, D18, D19, D20), checked before anything is
/// queued: nothing per member ever reaches a shared record, because the codec refuses it rather
/// than strip it on the way out. Refused: priv-only types; member-local fields; private chat
/// kinds; the fields only private chat kinds carry (`privateKindsOnly`: `Exchange.grading`,
/// `Exchange.score`, `Chat.overallScore`), so a review misfiled as a chat never carries a score
/// into a space; personal satellites; any write by a read-only participant; and a delete of a
/// Notebook, Artifact, Course or Chat by a participant who is neither the space owner nor its
/// `createdBy`. CloudKit enforces read-only itself; the delete rule is the clients' (CloudKit has
/// no per-record permissions). The JS port is `schema/js/space-guard.js`.
enum SpaceWriteGuard {
    /// The participant writing, from the space's CKShare.
    struct Writer: Equatable, Sendable {
        enum Permission: Equatable, Sendable {
            case readOnly
            case readWrite
        }

        /// The CloudKit user record name.
        let user: String
        let permission: Permission
        let isOwner: Bool

        init(user: String, permission: Permission, isOwner: Bool) {
            self.user = user
            self.permission = permission
            self.isOwner = isOwner
        }
    }

    enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case readOnlyParticipant
        /// A record type this build does not know is never written anywhere by it.
        case unknownType(String)
        case privateOnlyType(String)
        /// A value of a field the type's space rule limits (a private chat kind, D19).
        case privateKind(type: String, field: String, value: String)
        /// A field only private chat kinds carry (D20).
        case privateKindsOnlyField(type: String, field: String)
        case memberLocalField(type: String, field: String)
        case personalSatellite(type: String, field: String)
        case deleteNotAllowed(type: String)

        var description: String {
            switch self {
            case .readOnlyParticipant: return "A read-only participant cannot change this space."
            case .unknownType(let type): return "\(type) is not a record type this version writes."
            case .privateOnlyType(let type): return "\(type) is personal and never goes into a space."
            case .privateKind(let type, let field, let value): return "A \(type) whose \(field) is \(value) stays in your own library."
            case .privateKindsOnlyField(let type, let field): return "\(type).\(field) belongs to your own private chats and never goes into a space."
            case .memberLocalField(let type, let field): return "\(type).\(field) belongs to one member and never goes into a space."
            case .personalSatellite(let type, let field): return "\(type).\(field) points at a personal file, which stays in your own iCloud."
            case .deleteNotAllowed(let type): return "Only the space owner or whoever made this \(type) can delete it."
            }
        }
    }

    private static let ownedDeletes: Set<SyncRecordType> = [.notebook, .artifact, .course, .chat]

    /// Every refusal for writing a record of `type` that will hold `fields` (the held record with the
    /// patch applied) into a space. `spec` is the type's schema; it is a parameter so a test can
    /// show the guard refuses what the generator already keeps off shareable types.
    static func refusals(writing type: String, fields: [String: SyncJSON], by writer: Writer,
                         spec: SyncTypeSpec? = nil) -> [Refusal] {
        var refusals: [Refusal] = []
        if writer.permission == .readOnly { refusals.append(.readOnlyParticipant) }
        guard let spec = spec ?? SyncRecordType(rawValue: type)?.spec else { return refusals + [.unknownType(type)] }
        if spec.isPrivateOnly { refusals.append(.privateOnlyType(type)) }
        if let rule = spec.spaceRule {
            let value = fields[rule.field]?.stringValue ?? ""
            if !rule.allowedValues.contains(value) { refusals.append(.privateKind(type: type, field: rule.field, value: value)) }
        }
        for name in fields.keys.sorted() {
            guard let field = spec.field(name), let value = fields[name], value != .null else { continue }
            if field.isPrivateKindsOnly { refusals.append(.privateKindsOnlyField(type: type, field: name)) }
            if field.isMemberLocal { refusals.append(.memberLocalField(type: type, field: name)) }
            if field.json == "FileRef", holdsPersonalFile(value, kind: field.kind, personalField: field.isPersonalSatellite) {
                refusals.append(.personalSatellite(type: type, field: name))
            }
        }
        if spec.type == .content {
            let role = fields["role"]?.stringValue ?? ""
            if SyncSchema.personalSatelliteRoles.contains(role) || fields["personal"] == .bool(true) {
                refusals.append(.personalSatellite(type: type, field: "role"))
            }
        }
        return refusals
    }

    static func check(writing type: String, fields: [String: SyncJSON], by writer: Writer) throws {
        if let refusal = refusals(writing: type, fields: fields, by: writer).first { throw refusal }
    }

    /// Checks a patch against the record it will produce from `held` (nil for a create).
    static func check(_ patch: RecordPatch, onto held: SyncEnvelope?, by writer: Writer) throws {
        var fields = held?.fields ?? [:]
        for (name, change) in patch.changes {
            switch change {
            case .value(let value):
                fields[name] = value
            case .elements(let elements):
                var object = fields[name]?.objectValue ?? [:]
                for (key, value) in elements { object[key] = value }
                fields[name] = .object(object)
            }
        }
        try check(writing: patch.type.rawValue, fields: fields, by: writer)
    }

    /// Every refusal for deleting a record of `type` whose fields are `fields` from a space.
    static func refusals(deleting type: String, fields: [String: SyncJSON], by writer: Writer) -> [Refusal] {
        if writer.permission == .readOnly { return [.readOnlyParticipant] }
        guard let recordType = SyncRecordType(rawValue: type), ownedDeletes.contains(recordType), !writer.isOwner else { return [] }
        // Course has no createdBy (§3.5.9), so only the owner deletes a space's courses.
        let createdBy = fields["createdBy"].flatMap(SyncPerson.init(json:))
        return createdBy?.user == writer.user ? [] : [.deleteNotAllowed(type: type)]
    }

    static func check(deleting type: String, fields: [String: SyncJSON], by writer: Writer) throws {
        if let refusal = refusals(deleting: type, fields: fields, by: writer).first { throw refusal }
    }

    private static func holdsPersonalFile(_ value: SyncJSON, kind: SyncFieldKind, personalField: Bool) -> Bool {
        let files: [SyncJSON] = kind == .scalar ? [value] : Array((value.objectValue ?? [:]).values)
        return files.contains { file in
            guard file != .null else { return false }
            return personalField || (FileRef(json: file)?.isPersonal ?? false)
        }
    }
}
