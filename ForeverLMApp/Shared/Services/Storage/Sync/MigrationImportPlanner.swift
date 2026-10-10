import Foundation

// MARK: - What an import pass does with each old record (docs/cloudkit-schema-design.md §13.6)

/// The pass's decisions, as a pure function of the old records, the base and the world: no store, no
/// network, so the importer, any other Mac's import pass and (WP16b2) the refresh and the deferred
/// catch-up make the same decisions from the same inputs. The base can be the shared base or a Mac's
/// own snapshot; a field is applied only when its hash differs from it.
///
/// Per v2 record an old record gives:
/// - present: its fields whose hash differs from the base, each stamped with the old record's
///   modification date (`legacy22`, the letter its schema says), skipping one whose held stamp is
///   already later; a body by `MigrationBodyRule`, whatever the stamps;
/// - absent and listed in the manifest or a delta, or hanging from a record that is: deleted in the
///   new world, so skipped and logged;
/// - otherwise absent: created whole when the mapping creates it, or waited for when it only feeds it.
/// Then what the base lists as owned by the old record and the mapping no longer gives is removed by
/// type, except per-member state and history, anything the new world edited since T0, and what an
/// omitted key only failed to mention.
enum MigrationImportPlanner {
    /// How far a pass reaches into records the server holds. The import pass from the shared base reaches
    /// them all. The refresh and the deferred catch-up read from this Mac's own view, so they patch and
    /// remove only records the server does not hold: the server already holds every old-world change made
    /// before the base, a field their older view calls changed, re-applied with the old record's later
    /// date, would revert a build-N edit made since, and the import pass that follows brings the changes
    /// made since the base (§13.3, §13.4 step 0, R7-1, R7-x1).
    enum Reach: Sendable {
        case everything
        case absentOnly
    }

    struct Options: Sendable {
        var now: Date
        /// The learner answered Keep to a tripped 5% guard: removals are kept and listed, not made.
        var keepRemovals = false
        /// When the new world began: a stamp another device than the migration's made after it is an edit.
        var newWorldSince: Date?
        /// When each old record's values first waited, by `MigrationOldRecord.id`.
        var waitingSince: [String: Date] = [:]
        /// Prefix of a Recovered Doc's title.
        var recoveredTitlePrefix = "Recovered: "
        var reach = Reach.everything
        /// The world is this Mac's own rows (the refresh's and the deferred catch-up's), not the replica's:
        /// a body this Mac holds no edit of is the old-world body it last synced, so it is untouched.
        var ownRows = false

        init(
            now: Date, keepRemovals: Bool = false, newWorldSince: Date? = nil, waitingSince: [String: Date] = [:],
            reach: Reach = .everything, ownRows: Bool = false
        ) {
            self.now = now
            self.keepRemovals = keepRemovals
            self.newWorldSince = newWorldSince
            self.waitingSince = waitingSince
            self.reach = reach
            self.ownRows = ownRows
        }
    }

    /// A value waits this long for a record that does not exist yet before it is dropped and listed.
    static let waitLimit: TimeInterval = 30 * 86_400

    /// Which phase of a pass a giving belongs to: owned records first, then what the values of other old
    /// records feed into them.
    private static let phases: [LegacyGiving] = [.owns, .creates, .createsOnly, .feeds, .clears]

    static func plan(_ inputs: [MigrationOldRecordInput], world: MigrationWorld, options: Options) -> MigrationPassPlan {
        var state = State(world: world, options: options)
        var results = inputs.map { MigrationOldRecordPlan(oldRecord: $0.old.id) }
        var next = inputs.map { _ in [String: MigrationBaseRecord]() }

        for phase in phases {
            for (index, input) in inputs.enumerated() {
                for record in (input.old.mapping?.records ?? input.old.deletionRecords) where record.giving == phase {
                    apply(record, of: input, index: index, state: &state, result: &results[index], next: &next[index])
                }
            }
        }
        for (index, input) in inputs.enumerated() {
            removals(of: input, state: &state, result: &results[index], next: &next[index])
        }
        for index in inputs.indices {
            let input = inputs[index]
            if input.old.isDeleted {
                results[index].nextEntry = nil
            } else {
                results[index].nextEntry = MigrationBaseEntry(changeTag: input.old.changeTag, waiting: results[index].waiting, records: next[index])
            }
        }
        return MigrationPassPlan(olds: results, writes: state.orderedWrites, deletions: state.deletions)
    }

    // MARK: One v2 record

    private static func apply(
        _ record: LegacyV2Record, of input: MigrationOldRecordInput, index: Int, state: inout State,
        result: inout MigrationOldRecordPlan, next: inout [String: MigrationBaseRecord]
    ) {
        let old = input.old
        let key = MigrationRecordKey(record.type, record.id, spaceID: record.spaceID)
        let baseRecord = input.base?.records[record.key]
        let hashes = LegacyFieldHashes.hashes(record)
        let stamper = Stamper(modifiedAt: old.modifiedAt, provisional: isQueuedCapture(record) ? ["title", "url", "type"] : [])
        let handled = MigrationBaseRecord(owned: record.owned, hashes: hashes)

        if let held = state.current(key) {
            if record.giving != .createsOnly, !state.leavesToTheImport(key) {
                if patch(record, key: key, held: held, base: baseRecord, hashes: hashes, old: old, stamper: stamper, state: &state) {
                    // A change for a space this Mac may not write is never queued (SpaceSync would refuse it): the
                    // old record waits, with the base's hashes, until the space is writable or 30 days pass (F3).
                    wait(record, key: key, reason: .spaceMissing, old: old, baseRecord: baseRecord, handled: handled, state: state, result: &result, next: &next)
                    return
                }
            }
            next[record.key] = handled
            return
        }
        // Absent. Rows this Mac derived and has not uploaded are its reconcile's: its catch-up already
        // brought them the old world's changes.
        if state.world.isLocalOnly(key) {
            next[record.key] = handled
            return
        }
        // A record the new world deleted stays deleted, and so does what hangs from one.
        if state.world.isListed(key) {
            result.skipped.append(log(old, key, .deletedInNewWorld, options: state.options))
            next[record.key] = handled
            return
        }
        if let parent = parent(of: record), state.current(parent) == nil, state.world.isListed(parent) {
            result.skipped.append(log(old, key, .parentDeletedInNewWorld, options: state.options))
            next[record.key] = handled
            return
        }
        switch record.giving {
        case .clears:
            // An old record's default state is no change to a record that was never made, and it is listed in
            // the base so a later write of the old record that says the same does not clear what the new world
            // made since (F2).
            next[record.key] = handled
            return
        case .feeds:
            wait(record, key: key, reason: .waitedTooLong, old: old, baseRecord: baseRecord, handled: handled, state: state, result: &result, next: &next)
        case .owns, .creates, .createsOnly:
            if let spaceID = key.spaceID, !state.world.holdsSpace(spaceID) {
                wait(record, key: key, reason: .spaceMissing, old: old, baseRecord: baseRecord, handled: handled, state: state, result: &result, next: &next)
                return
            }
            create(record, key: key, old: old, stamper: stamper, state: &state)
            next[record.key] = handled
        }
    }

    /// A value for a record that cannot be created yet: the old record waits, keeping the hashes the base
    /// had for it so every later pass maps it again, until the record exists, a listing shows it deleted,
    /// or 30 days pass (§13.6).
    private static func wait(
        _ record: LegacyV2Record, key: MigrationRecordKey, reason: MigrationLogEntry.Reason, old: MigrationOldRecord,
        baseRecord: MigrationBaseRecord?, handled: MigrationBaseRecord, state: State,
        result: inout MigrationOldRecordPlan, next: inout [String: MigrationBaseRecord]
    ) {
        let since = state.options.waitingSince[old.id] ?? state.options.now
        if state.options.now.timeIntervalSince(since) >= waitLimit {
            result.notApplied.append(log(old, key, reason == .spaceMissing ? .spaceMissing : .waitedTooLong, options: state.options))
            next[record.key] = handled
            return
        }
        result.waiting = true
        result.waitingKeys.insert(record.key)
        if let baseRecord { next[record.key] = baseRecord }
    }

    // MARK: Create whole

    private static func create(_ record: LegacyV2Record, key: MigrationRecordKey, old: MigrationOldRecord, stamper: Stamper, state: inout State) {
        var write = MigrationWrite(key: key, creates: true)
        for (field, value) in record.fields.sorted(by: { $0.key < $1.key }) {
            guard let spec = record.type.spec.field(field), !value.isNull else { continue }
            switch spec.kind {
            case .scalar:
                write.changes[field] = .value(value)
                write.stamps[StampedPath(field)] = stamper.stamp(spec.policy, field)
            case .map, .set:
                let elements = (value.objectValue ?? [:]).filter { !$0.value.isNull }
                guard !elements.isEmpty else { continue }
                write.changes[field] = .elements(elements)
                for element in elements.keys { write.stamps[StampedPath(field, element: element)] = stamper.stamp(spec.policy, field) }
            }
        }
        if record.type == .artifact, write.changes["body"] != nil { write.bodySource = bodySource(of: record, old: old) }
        state.record(write)
    }

    // MARK: Patch a record that exists

    /// True when the record has a change to make in a space this Mac may not write: nothing is queued, and the
    /// caller makes the old record wait.
    @discardableResult
    private static func patch(
        _ record: LegacyV2Record, key: MigrationRecordKey, held: SyncEnvelope, base: MigrationBaseRecord?, hashes: [String: String],
        old: MigrationOldRecord, stamper: Stamper, state: inout State
    ) -> Bool {
        var write = MigrationWrite(key: key, creates: false)
        let existing = state.world.held(key)
        for (field, value) in record.fields.sorted(by: { $0.key < $1.key }) {
            guard !record.createOnlyFields.contains(field), let spec = record.type.spec.field(field) else { continue }
            if record.type == .artifact, field == "body" {
                body(record, value: value, held: existing, base: base, hashes: hashes, key: key, old: old, stamper: stamper, state: &state, write: &write)
                continue
            }
            switch spec.kind {
            case .scalar:
                guard base?.hashes[field] != hashes[field] else { continue }
                if let change = scalarChange(field, value, spec: spec, held: held, stamper: stamper) {
                    write.changes[field] = .value(value)
                    write.stamps[StampedPath(field)] = change
                }
            case .map, .set:
                let elements = value.objectValue ?? [:]
                var changes: [String: SyncJSON] = [:]
                let held = held.fields[field]?.objectValue ?? [:]
                let heldStamps: [String: SyncStamp] = if case .elements(let stamps)? = state.current(key)?.stamps[field] { stamps } else { [:] }
                for (element, elementValue) in elements.sorted(by: { $0.key < $1.key }) where base?.hashes["\(field)/\(element)"] != hashes["\(field)/\(element)"] {
                    if let current = held[element], SyncEnvelope.sameWireValue(current, elementValue) { continue }
                    let stamp = stamper.stamp(spec.policy, field)
                    if let present = heldStamps[element], spec.policy == .lastWriter, !stamp.isLater(than: present) { continue }
                    changes[element] = elementValue
                    write.stamps[StampedPath(field, element: element)] = stamp
                }
                // An owner gives its structure whole: an element the base listed that it no longer gives leaves.
                if record.wholeFields.contains(field), let base {
                    let prefix = "\(field)/"
                    for hashKey in base.hashes.keys where hashKey.hasPrefix(prefix) {
                        let element = String(hashKey.dropFirst(prefix.count))
                        guard elements[element] == nil, let current = held[element], !current.isNull, current != .bool(false) else { continue }
                        let stamp = stamper.stamp(spec.policy, field)
                        if let present = heldStamps[element], spec.policy == .lastWriter, !stamp.isLater(than: present) { continue }
                        changes[element] = spec.kind == .set ? .bool(false) : .null
                        write.stamps[StampedPath(field, element: element)] = stamp
                    }
                }
                if !changes.isEmpty { write.changes[field] = .elements(changes) }
            }
        }
        guard !write.changes.isEmpty else { return false }
        if let spaceID = key.spaceID, !state.world.holdsSpace(spaceID) { return true }
        state.record(write)
        return false
    }

    /// The stamp for a scalar field the old record changed, or nil when the held value already stands: it is
    /// the same value, or carries a later stamp (a later new-world edit always wins), or, for a server-first
    /// field, a first write already stands (§6.1).
    private static func scalarChange(_ field: String, _ value: SyncJSON, spec: SyncFieldSpec, held: SyncEnvelope, stamper: Stamper) -> SyncStamp? {
        let stamp = stamper.stamp(spec.policy, field)
        if let current = held.fields[field], SyncEnvelope.sameWireValue(current, value) { return nil }
        guard case .value(let present)? = held.stamps[field] else { return stamp }
        switch spec.policy {
        case .lastWriter, .textBody:
            return stamp.isLater(than: present) ? stamp : nil
        case .serverFirst:
            return present.milliseconds <= Int64(SyncSchema.Limits.provisionalStampMs) ? stamp : nil
        case .maximum, .minimum:
            return stamp
        }
    }

    // MARK: A body

    private static func body(
        _ record: LegacyV2Record, value: SyncJSON, held: MigrationHeldRecord?, base: MigrationBaseRecord?, hashes: [String: String],
        key: MigrationRecordKey, old: MigrationOldRecord, stamper: Stamper, state: inout State, write: inout MigrationWrite
    ) {
        let isNotes = NotesDoc.notebookID(of: record.id) != nil
        // A Doc whose package was not fetched gives no body to apply, and no body is cleared on that account.
        guard value.isNull ? isNotes : FileRef(json: value) != nil, let oldHash = hashes["body"] else { return }
        // From this Mac's own rows, a body it holds no edit of is the one it last synced: the base's.
        let ownEdit = state.world.ownBodyEdit(key)
        // Rows that already hold the old body (the same package hash) have nothing to take.
        if state.options.ownRows, !ownEdit, let rows = held?.replicaBodyHash, rows == oldHash { return }
        let replicaHash = state.options.ownRows && !ownEdit ? base?.hashes["body"] : held?.replicaBodyHash
        let outcome = MigrationBodyRule.decide(
            oldHash: oldHash, baseHash: base?.hashes["body"], replicaHash: replicaHash, pendingHash: held?.pendingBodyHash, ownEdit: ownEdit
        )
        switch outcome {
        case .nothing:
            return
        case .apply:
            write.changes["body"] = .value(value)
            write.stamps[StampedPath("body")] = stamper.stamp(record.type.spec.field("body")?.policy ?? .textBody)
            if !value.isNull { write.bodySource = bodySource(of: record, old: old) }
        case .recover:
            // Cleared notes leave nothing to recover.
            guard !value.isNull else { return }
            recover(record, hash: oldHash, old: old, stamper: stamper, state: &state)
        }
    }

    /// The Recovered Doc for an old body that lost to the new world's (§13.6, R5-2, R6-3): in the same
    /// notebook, under the id every pass that meets the difference makes. Skipped when it exists, or the
    /// learner deleted it.
    private static func recover(_ record: LegacyV2Record, hash: String, old: MigrationOldRecord, stamper: Stamper, state: inout State) {
        let id = MigrationBodyRule.recoveredID(artifactID: record.id, hash: hash)
        let key = MigrationRecordKey(.artifact, id, spaceID: record.spaceID)
        guard state.current(key) == nil, !state.world.isListed(key), !state.world.isLocalOnly(key) else { return }
        var write = MigrationWrite(key: key, creates: true)
        var fields = record.fields
        // A Notes Doc's body is its notes as Markdown text; its Recovered Doc is an ordinary Doc, whose body
        // is a Markdown package.
        if NotesDoc.notebookID(of: record.id) != nil { fields["bodyFormat"] = .string("markdownPackage") }
        fields["title"] = .string(state.options.recoveredTitlePrefix + (record.fields["title"]?.stringValue ?? ""))
        fields["kind"] = .string("doc")
        fields["body"] = .null
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard let spec = record.type.spec.field(field) else { continue }
            if field == "body" {
                write.changes["body"] = .value(.null)
                write.stamps[StampedPath("body")] = stamper.stamp(spec.policy, field)
                continue
            }
            guard !value.isNull else { continue }
            switch spec.kind {
            case .scalar:
                write.changes[field] = .value(value)
                write.stamps[StampedPath(field)] = stamper.stamp(spec.policy, field)
            case .map, .set:
                let elements = (value.objectValue ?? [:]).filter { !$0.value.isNull }
                guard !elements.isEmpty else { continue }
                write.changes[field] = .elements(elements)
                for element in elements.keys { write.stamps[StampedPath(field, element: element)] = stamper.stamp(spec.policy, field) }
            }
        }
        write.isRecoveredDoc = true
        write.bodySource = bodySource(of: record, old: old)
        state.record(write)
    }

    private static func bodySource(of record: LegacyV2Record, old: MigrationOldRecord) -> MigrationBodySource {
        NotesDoc.notebookID(of: record.id) != nil ? .notes(oldRecord: old.id) : .docPackage(oldRecord: old.id)
    }

    // MARK: Removal, only of what an old record owns

    private static func removals(
        of input: MigrationOldRecordInput, state: inout State, result: inout MigrationOldRecordPlan, next: inout [String: MigrationBaseRecord]
    ) {
        guard let base = input.base else { return }
        let old = input.old
        let given = Set((old.mapping?.records ?? old.deletionRecords).map(\.key))
        for (baseKey, baseRecord) in base.records.sorted(by: { $0.key < $1.key }) where !given.contains(baseKey) {
            guard let key = MigrationRecordKey(baseKey: baseKey, spaceID: old.spaceID) else { continue }
            // An omitted key says nothing: it clears no value and never counts as a removed child (R6-m4).
            if old.mapping?.isSilent(on: key.type, id: key.id) == true {
                next[baseKey] = baseRecord
                continue
            }
            guard baseRecord.owned else {
                result.kept.append(log(old, key, .notOwned, options: state.options))
                continue
            }
            guard let held = state.current(key) else { continue }
            // The server holds it: the import pass from the shared base removes it against the base. From this
            // Mac's own view (a catch-up's or a refresh's) a record the server holds is never removed, whether
            // the pass patches such records or not: if the seed put it there the importer removes it, and
            // otherwise the new world made it (§13.3, R6-1).
            if state.heldByServer(key) || state.leavesToTheImport(key) { continue }
            if LegacyOwnership.neverRemoved.contains(key.type) {
                result.kept.append(log(old, key, .neverRemoved, options: state.options))
            } else if state.isEditedInNewWorld(held) || state.world.hasLocalChange(key) {
                result.kept.append(log(old, key, .editedInNewWorld, options: state.options))
            } else if state.options.keepRemovals {
                result.kept.append(log(old, key, .keptByAnswer, options: state.options))
            } else {
                state.remove(key, held: held, stamper: Stamper(modifiedAt: old.modifiedAt))
                result.removals += 1
            }
        }
    }

    // MARK: Helpers

    /// An old Source that is still a queued capture: an old iPhone wrote its URL as the title and guessed
    /// its type, so those take provisional stamps and never beat a real value (§13.6, R6-m11).
    private static func isQueuedCapture(_ record: LegacyV2Record) -> Bool {
        record.type == .source && record.fields["ingest"]?.objectValue?["state"]?.stringValue == "queued"
    }

    /// The record a record hangs from (an Entry's container, an Exchange's chat, a Lesson's or Quiz's
    /// course, a Comment's Doc), by the home rule its type is placed by (§4.4).
    static func parent(of record: LegacyV2Record) -> MigrationRecordKey? {
        switch record.type.spec.home.rule {
        case .parent(let field, let parent):
            return record.fields[field]?.stringValue.map { MigrationRecordKey(parent, $0, spaceID: record.spaceID) }
        case .container(let field, let kindField, let parents):
            guard let kind = record.fields[kindField]?.stringValue, let parent = parents[kind], let id = record.fields[field]?.stringValue else { return nil }
            return MigrationRecordKey(parent, id, spaceID: record.spaceID)
        case .library, .current, .owner:
            return nil
        }
    }

    private static func log(_ old: MigrationOldRecord, _ key: MigrationRecordKey, _ reason: MigrationLogEntry.Reason, options: Options) -> MigrationLogEntry {
        MigrationLogEntry(oldRecord: old.id, type: key.type.rawValue, id: key.id, reason: reason, at: options.now)
    }

    /// Stamps of migrated fields: the old record's modification date, never "now" (§13.4 step 4, §13.6).
    struct Stamper {
        let milliseconds: Int64

        init(modifiedAt: Date, provisional: Set<String> = []) {
            self.provisional = provisional
            milliseconds = min(max(SyncTime.milliseconds(modifiedAt), Int64(SyncSchema.Limits.provisionalStampMs)), SyncStamp.maxMilliseconds)
        }

        /// Fields stamped provisionally: a queued capture's guessed title, url and type (§3.5.4, R6-m11).
        let provisional: Set<String>

        func stamp(_ policy: SyncPolicy, _ field: String? = nil) -> SyncStamp {
            if let field, provisional.contains(field) { return SyncStamp.provisional(policy, deviceID: SyncIdentity.legacyDeviceID) }
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: 0, deviceID: SyncIdentity.legacyDeviceID)
        }
    }

    // MARK: The pass's running view

    /// What the pass has decided so far, so a record created by an owner is there for the values other
    /// old records feed into it, and two old records' values for one record fold into one write.
    struct State {
        let world: MigrationWorld
        let options: Options
        private(set) var overlay: [MigrationRecordKey: SyncEnvelope] = [:]
        private var writes: [MigrationRecordKey: MigrationWrite] = [:]
        private var order: [MigrationRecordKey] = []
        private(set) var deletions: [MigrationRemoval] = []
        private var removed: Set<MigrationRecordKey> = []

        init(world: MigrationWorld, options: Options) {
            self.world = world
            self.options = options
        }

        /// The record's envelope: the world's, with what this pass has written over it; nil when absent.
        func current(_ key: MigrationRecordKey) -> SyncEnvelope? {
            if removed.contains(key) { return nil }
            return overlay[key] ?? world.held(key)?.merged
        }

        /// The writes in the order a sender needs them: creates before patches.
        var orderedWrites: [MigrationWrite] {
            let all = order.compactMap { writes[$0] }
            return all.filter(\.creates) + all.filter { !$0.creates }
        }

        mutating func record(_ write: MigrationWrite) {
            var merged = writes[write.key] ?? MigrationWrite(key: write.key, creates: write.creates)
            if write.creates { merged.creates = true }
            if write.bodySource != nil { merged.bodySource = write.bodySource }
            merged.isRecoveredDoc = merged.isRecoveredDoc || write.isRecoveredDoc
            merged.removes = merged.removes || write.removes
            for (field, change) in write.changes {
                switch change {
                case .value:
                    let path = StampedPath(field)
                    guard let stamp = write.stamps[path] else { continue }
                    if let held = merged.stamps[path], !stamp.isLater(than: held) { continue }
                    merged.changes[field] = change
                    merged.stamps[path] = stamp
                case .elements(let elements):
                    var kept = merged.changes[field].flatMap { change -> [String: SyncJSON]? in
                        if case .elements(let existing) = change { return existing }
                        return nil
                    } ?? [:]
                    for (element, value) in elements {
                        let path = StampedPath(field, element: element)
                        guard let stamp = write.stamps[path] else { continue }
                        if let held = merged.stamps[path], !stamp.isLater(than: held) { continue }
                        kept[element] = value
                        merged.stamps[path] = stamp
                    }
                    merged.changes[field] = .elements(kept)
                }
            }
            if writes[write.key] == nil { order.append(write.key) }
            writes[write.key] = merged
            var envelope = overlay[write.key] ?? world.held(write.key)?.merged ?? SyncEnvelope.new(write.key.type, id: write.key.id, saltID: "")
            let stamps = write.stamps
            _ = try? envelope.apply(RecordPatch(write.key.type, id: write.key.id, changes: write.changes)) { path, policy, _ in
                stamps[path] ?? SyncStamp(policy: policy, milliseconds: 1, counter: 0, deviceID: SyncIdentity.legacyDeviceID)
            }
            overlay[write.key] = envelope
        }

        /// An old record's removal of a record it owned: Entry and Placement flip `state`, a Setting clears
        /// `value`, any other type is deleted.
        mutating func remove(_ key: MigrationRecordKey, held: SyncEnvelope, stamper: Stamper) {
            switch key.type {
            case .entry, .placement:
                guard held.fields["state"]?.stringValue != "removed" else { return }
                record(flip(key, field: "state", value: .string("removed"), stamper: stamper))
            case .setting:
                guard let value = held.fields["value"], !value.isNull else { return }
                record(flip(key, field: "value", value: .null, stamper: stamper))
            default:
                deletions.append(MigrationRemoval(key: key, deletes: true))
                removed.insert(key)
            }
        }

        private func flip(_ key: MigrationRecordKey, field: String, value: SyncJSON, stamper: Stamper) -> MigrationWrite {
            var write = MigrationWrite(key: key, creates: false)
            write.changes[field] = .value(value)
            write.stamps[StampedPath(field)] = stamper.stamp(.lastWriter)
            write.removes = true
            return write
        }

        /// A record the server holds, in a pass that reaches only what it does not (`Reach.absentOnly`).
        func leavesToTheImport(_ key: MigrationRecordKey) -> Bool {
            options.reach == .absentOnly && world.held(key)?.inReplica == true
        }

        /// A record the server holds, in a pass over this Mac's own rows (`Options.ownRows`).
        func heldByServer(_ key: MigrationRecordKey) -> Bool {
            options.ownRows && world.held(key)?.inReplica == true
        }

        /// Whether the new world edited the record since T0: a field stamped by a device other than the
        /// migration's, after the new world began.
        func isEditedInNewWorld(_ envelope: SyncEnvelope) -> Bool {
            let since = options.newWorldSince.map(SyncTime.milliseconds) ?? 0
            func edited(_ stamp: SyncStamp) -> Bool { stamp.deviceID != SyncIdentity.legacyDeviceID && stamp.milliseconds > since }
            for stamp in envelope.stamps.values {
                switch stamp {
                case .value(let stamp): if edited(stamp) { return true }
                case .elements(let elements): if elements.values.contains(where: edited) { return true }
                }
            }
            return false
        }
    }
}
