import Foundation
import OSLog

/// Which of a set of duplicate Sources wins (docs/cloudkit-schema-design.md §4.2, D22, PD-13, IC-20):
/// a paper with its PDF, then one with a `text` satellite, then one filed under the work's own address
/// over one filed under a Substack app link, then the smaller id (uppercase UUIDs sort before `src_`,
/// so the id alone could pick a paper without its PDF).
enum DuplicateSources {
    struct Candidate: Equatable, Sendable {
        let id: String
        let envelope: SyncEnvelope

        var workKeys: Set<String> {
            Set((envelope.fields["workKeys"]?.objectValue ?? [:]).compactMap { $0.value == .bool(true) ? $0.key : nil })
        }

        func file(_ map: String, _ role: String) -> FileRef? {
            envelope.fields[map]?.objectValue?[role].flatMap(FileRef.init(json:))
        }

        var isPaperWithPDF: Bool { envelope.fields["type"]?.stringValue == "paper" && file("files", "pdf") != nil }
        var hasText: Bool { file("files", "text") != nil }
        /// Filed under a link Substack's reader gives a post (`SubstackAppLink`) and not the post's own
        /// address. Read through the reader, such a copy is titled and credited by the publication
        /// ("<post> - <publication>"); the copy from the post's own page carries the post's title and its
        /// author, so it is the one a fold keeps (the product owner, 2026-11-12: "make the fold keep the
        /// copy with the cleaner title").
        var isFiledUnderAppLink: Bool { envelope.fields["url"]?.stringValue.map(SubstackAppLink.isAppLink) ?? false }
        /// Active and not yet anyone's loser.
        var isLive: Bool { envelope.fields["status"]?.stringValue == "active" && (envelope.fields["mergedInto"]?.stringValue ?? "").isEmpty }
        /// The winner a resolution redirected this Source to and did not finish: the redirect stands (S, the
        /// first acknowledged resolution), and the pass that wrote it was lost or cut short before the
        /// loser was archived, which is the last write of a resolution.
        var unfinishedWinner: String? {
            guard envelope.fields["status"]?.stringValue == "active", let into = envelope.fields["mergedInto"]?.stringValue, !into.isEmpty else { return nil }
            return into
        }
    }

    static func winner(_ candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            if lhs.isPaperWithPDF != rhs.isPaperWithPDF { return lhs.isPaperWithPDF }
            if lhs.hasText != rhs.hasText { return lhs.hasText }
            if lhs.isFiledUnderAppLink != rhs.isFiledUnderAppLink { return rhs.isFiledUnderAppLink }
            return lhs.id < rhs.id
        }
    }

    /// The groups of live Sources that share a work key, each with two or more members, by id.
    static func groups(_ candidates: [Candidate]) -> [[Candidate]] {
        let live = candidates.filter(\.isLive).sorted { $0.id < $1.id }
        var parent = Array(live.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var byKey: [String: Int] = [:]
        for (index, candidate) in live.enumerated() {
            for key in candidate.workKeys.sorted() {
                if let other = byKey[key] {
                    let (a, b) = (find(index), find(other))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    byKey[key] = index
                }
            }
        }
        let grouped = Dictionary(grouping: live.indices, by: find)
        return grouped.values.filter { $0.count > 1 }.map { $0.map { live[$0] } }.sorted { $0[0].id < $1[0].id }
    }

    /// An Entry's id with its item replaced: `en:<containerID>:source:<itemID>`, keeping a `#<n>` span.
    static func twinID(of entryID: String, loser: String, winner: String) -> String {
        let (base, span) = entryID.firstIndex(of: "#").map { (String(entryID[..<$0]), String(entryID[$0...])) } ?? (entryID, "")
        guard base.hasSuffix(":source:" + loser) else { return entryID }
        return String(base.dropLast(loser.count)) + winner + span
    }
}

/// Duplicate resolution (§4.2), on the maintenance-lease Mac after a round that fetched every zone to
/// the end, in `Catalog` and in the spaces it owns. For each loser:
/// - the loser gets `mergedInto = winner` (S: the first acknowledged resolution stands, and a loser
///   whose redirect did not land is left for the next pass) and `status = archived`, and is kept for
///   ever as a redirect that `resolveSource()` follows, so the Highlights, Cards, Sitting answers and
///   citations that name it show on the winner;
/// - the winner gains the loser's work keys, and for every `files` and `derived` role it lacks, the
///   loser's FileRef verbatim (same zone, so its satellite names stay valid, D41);
/// - every live Entry naming the loser gets a twin naming the winner in the same container, its
///   `state`, `approval` and `orderKey` copied with their stamps, and its own `state = removed`;
/// - in this learner's `Library`, the loser's ReadingState, Placement and Marks are folded into the
///   winner's, field by field, the newer stamp winning, and `NotebookState.excluded` entries are
///   re-keyed onto the winner against the winner's Entry, so an excluded loser stays unticked.
extension MaintenanceService {
    private static let duplicateLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "DuplicateSources")

    /// One pass. Returns how many losers it resolved.
    func resolveDuplicates() async throws -> Int {
        let zoneKeys = try await store.perform { state -> [String] in
            var keys = [PrivateSyncZones.key(PrivateSyncZones.catalog)]
            try state.connection.query(
                "SELECT zone_key FROM ck_zones WHERE database = 'private' AND kind = 'space' ORDER BY zone_key", []
            ) { keys.append($0.text(0) ?? "") }
            return keys
        }
        var resolved = 0
        for zoneKey in zoneKeys {
            guard let sourceZone = try await zone(zoneKey), let library = try await zone(PrivateSyncZones.libraryKey) else { continue }
            let candidates = try await records(of: .source, in: zoneKey).map { DuplicateSources.Candidate(id: $0.key, envelope: $0.value) }
            // A resolution a lost write or a quit cut short is finished first, into the winner it chose.
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for loser in candidates where loser.unfinishedWinner != nil {
                guard let winner = loser.unfinishedWinner.flatMap({ byID[$0] }), winner.id != loser.id else { continue }
                if try await complete(loser, into: winner, in: sourceZone, library: library) { resolved += 1 }
            }
            for group in DuplicateSources.groups(candidates) {
                guard let winner = DuplicateSources.winner(group) else { continue }
                for loser in group where loser.id != winner.id {
                    if try await resolve(loser, into: winner, in: sourceZone, library: library) { resolved += 1 }
                }
            }
        }
        if resolved > 0 { Self.duplicateLogger.info("Resolved \(resolved) duplicate sources") }
        return resolved
    }

    /// Every record of `type` in a zone, by logical id.
    private func records(of type: SyncRecordType, in zoneKey: String) async throws -> [String: SyncEnvelope] {
        try await store.perform { state in
            var found: [String: SyncEnvelope] = [:]
            try state.connection.query(
                "SELECT wire_id, payload FROM ck_records WHERE zone_key = ? AND record_type = ?", [.text(zoneKey), .text(type.rawValue)]
            ) { row in
                if let payload = row.blob(1), let envelope = try? SyncEnvelope(storedPayload: payload) { found[row.text(0) ?? ""] = envelope }
            }
            return found
        }
    }

    private func resolve(_ loser: DuplicateSources.Candidate, into winner: DuplicateSources.Candidate, in zone: BlobZone, library: BlobZone) async throws -> Bool {
        // The redirect first: when another resolution of this loser stood, nothing else is written. The
        // loser stays active until the last write, so a resolution that stops anywhere in between is
        // seen again by `unfinishedWinner` and finished (F11), and never archives a loser whose winner
        // did not receive what it holds.
        var redirect = RecordPatch(.source, id: loser.id)
        redirect.changes["mergedInto"] = .value(.string(winner.id))
        guard try await writer.save([MaintenanceWriter.Write(zone: zone, patch: redirect)]).first == .saved else { return false }
        return try await complete(loser, into: winner, in: zone, library: library)
    }

    /// Everything a resolution does after the redirect, each write one that is no change when it already
    /// landed, and the loser's `status = archived` last, only when every other write was acknowledged.
    private func complete(_ loser: DuplicateSources.Candidate, into winner: DuplicateSources.Candidate, in zone: BlobZone, library: BlobZone) async throws -> Bool {
        var gains = RecordPatch(.source, id: winner.id)
        let newKeys = loser.workKeys.subtracting(winner.workKeys)
        if !newKeys.isEmpty { gains.changes["workKeys"] = .elements(Dictionary(newKeys.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })) }
        for map in ["files", "derived"] {
            let held = winner.envelope.fields[map]?.objectValue ?? [:]
            var copied: [String: SyncJSON] = [:]
            for (role, value) in loser.envelope.fields[map]?.objectValue ?? [:] where FileRef(json: value) != nil && FileRef(json: held[role] ?? .null) == nil {
                copied[role] = value
            }
            if !copied.isEmpty { gains.changes[map] = .elements(copied) }
        }
        var writes: [MaintenanceWriter.Write] = []
        if !gains.changes.isEmpty { writes.append(MaintenanceWriter.Write(zone: zone, patch: gains)) }

        // Entries: Library's (notebooks, Goals, lessons) and Catalog's (playlists), or the space's own.
        let entryZones = zone.isSpace ? [zone] : [library, zone]
        var twins: [String: SyncNotebookChatContext.Entry] = [:]
        var loserPairs: [String: String] = [:]
        for entryZone in entryZones {
            let entries = try await records(of: .entry, in: entryZone.zoneKey)
            for (id, entry) in entries.sorted(by: { $0.key < $1.key })
            where entry.fields["itemKind"]?.stringValue == "source" && entry.fields["itemID"]?.stringValue == loser.id
                && entry.fields["state"]?.stringValue != "removed" {
                if let held = SyncNotebookChatContext.Entry(entry) { loserPairs[held.containerID] = SyncNotebookChatContext.stampPair(held) }
                let twinID = DuplicateSources.twinID(of: id, loser: loser.id, winner: winner.id)
                if let existing = entries[twinID] {
                    if let held = SyncNotebookChatContext.Entry(existing) { twins[held.containerID] = held }
                } else {
                    var twin = RecordPatch(.entry, id: twinID)
                    var verbatim: [StampedPath: SyncStamp] = [:]
                    for (field, value) in entry.fields where field != "editedAt" {
                        twin.changes[field] = .value(field == "itemID" ? .string(winner.id) : value)
                        if ["state", "approval", "orderKey"].contains(field), case .value(let stamp)? = entry.stamps[field] {
                            verbatim[StampedPath(field)] = stamp
                        }
                    }
                    twin.changes["editedAt"] = .value(SyncJSON(SyncTime.milliseconds(clockNow())))
                    writes.append(MaintenanceWriter.Write(zone: entryZone, patch: twin, verbatim: verbatim))
                    var copy = entry
                    copy.fields["itemID"] = .string(winner.id)
                    if let held = SyncNotebookChatContext.Entry(copy) { twins[held.containerID] = held }
                }
                var removed = RecordPatch(.entry, id: id)
                removed.changes["state"] = .value(.string("removed"))
                writes.append(MaintenanceWriter.Write(zone: entryZone, patch: removed))
            }
        }

        writes += try await personalFolds(loser: loser.id, winner: winner.id, twins: twins, loserPairs: loserPairs, in: library)
        let outcomes = try await writer.save(writes)
        guard outcomes.allSatisfy({ $0 == .saved || $0 == .unchanged }) else {
            Self.duplicateLogger.error("Some writes of a duplicate's resolution did not land; the next pass finishes it")
            return false
        }
        var archive = RecordPatch(.source, id: loser.id)
        archive.changes["status"] = .value(.string("archived"))
        let archived = try await writer.save([MaintenanceWriter.Write(zone: zone, patch: archive)]).first
        return archived == .saved || archived == .unchanged
    }

    /// The learner's own state about the loser, folded onto the winner in `Library`.
    private func personalFolds(loser: String, winner: String, twins: [String: SyncNotebookChatContext.Entry],
                               loserPairs: [String: String], in library: BlobZone) async throws -> [MaintenanceWriter.Write] {
        var writes: [MaintenanceWriter.Write] = []
        let readingStates = try await records(of: .readingState, in: library.zoneKey)
        if let from = readingStates["rs:\(loser)"] {
            writes += Self.fold(from, into: readingStates["rs:\(winner)"], type: .readingState, id: "rs:\(winner)",
                                identity: ["targetID": .string(winner), "targetKind": from.fields["targetKind"] ?? .string("source")], zone: library)
        }
        let placements = try await records(of: .placement, in: library.zoneKey)
        if let from = placements["pl:\(loser)"] {
            writes += Self.fold(from, into: placements["pl:\(winner)"], type: .placement, id: "pl:\(winner)",
                                identity: ["sourceID": .string(winner)], zone: library)
        }
        let marks = try await records(of: .mark, in: library.zoneKey)
        for (id, mark) in marks.sorted(by: { $0.key < $1.key }) {
            guard let target = mark.fields["target"]?.stringValue, let kind = mark.fields["kind"]?.stringValue else { continue }
            let named = target == "src:\(loser)" || target.hasPrefix("src:\(loser)#")
            guard named else { continue }
            let newTarget = "src:\(winner)" + target.dropFirst("src:\(loser)".count)
            let newID = "mk:\(kind):\(newTarget)"
            guard newID != id else { continue }
            writes += Self.fold(mark, into: marks[newID], type: .mark, id: newID, identity: ["target": .string(newTarget), "kind": .string(kind)], zone: library)
        }
        for (id, notebookState) in try await records(of: .notebookState, in: library.zoneKey).sorted(by: { $0.key < $1.key }) {
            // Only an exclusion that still holds (its pair is the loser's Entry's) moves to the winner.
            guard let notebookID = notebookState.fields["notebookID"]?.stringValue,
                  let pair = notebookState.fields["excluded"]?.objectValue?[loser]?.stringValue, pair == loserPairs[notebookID],
                  let twin = twins[notebookID]
            else { continue }
            let patch = RecordPatch(.notebookState, id: id, changes: [
                "excluded": .elements([loser: .null, winner: .string(SyncNotebookChatContext.stampPair(twin))]),
            ])
            writes.append(MaintenanceWriter.Write(zone: library, patch: patch))
        }
        return writes
    }

    /// `from`'s fields onto the record `id`, each where `from`'s stamp is newer than what `into` holds
    /// (per element for maps and sets), with `from`'s own stamps; the identity fields name the winner.
    static func fold(_ from: SyncEnvelope, into: SyncEnvelope?, type: SyncRecordType, id: String,
                     identity: [String: SyncJSON], zone: BlobZone) -> [MaintenanceWriter.Write] {
        var patch = RecordPatch(type, id: id)
        var verbatim: [StampedPath: SyncStamp] = [:]
        for (field, value) in from.fields where identity[field] == nil && field != "editedAt" {
            switch from.stamps[field] {
            case .value(let stamp)?:
                if case .value(let held)? = into?.stamps[field], held.isLater(than: stamp) || held == stamp { continue }
                patch.changes[field] = .value(value)
                verbatim[StampedPath(field)] = stamp
            case .elements(let stamps)?:
                let heldStamps: [String: SyncStamp] = if case .elements(let held)? = into?.stamps[field] { held } else { [:] }
                var elements: [String: SyncJSON] = [:]
                for (element, stamp) in stamps {
                    if let held = heldStamps[element], held.isLater(than: stamp) || held == stamp { continue }
                    elements[element] = value.objectValue?[element] ?? .null
                    verbatim[StampedPath(field, element: element)] = stamp
                }
                if !elements.isEmpty { patch.changes[field] = .elements(elements) }
            case nil:
                continue
            }
        }
        guard !patch.changes.isEmpty else { return [] }
        if into == nil {
            for (field, value) in identity { patch.changes[field] = .value(value) }
        }
        patch.changes["editedAt"] = .value(SyncJSON(max(from.fields["editedAt"]?.int64Value ?? 0, into?.fields["editedAt"]?.int64Value ?? 0)))
        return [MaintenanceWriter.Write(zone: zone, patch: patch, verbatim: verbatim)]
    }
}
