import Foundation

/// The merge (§6.2): `merge(server S, local L, base B) → M`, field by field, by the policy letter of
/// the server's stamp. S is the server record's envelope, L the local envelope (local state patched
/// onto the replica's raw payload) and B the last acknowledged envelope this device holds (nil for a
/// create). M starts as a copy of S, so unknown fields and top-level keys of S survive, and takes a
/// field or element from L only by its policy:
///
/// - **L** last writer: L wins when its stamp is the later one. It also wins when the caller says
///   the local stamp was minted against the server's current stamp for that path (`mintedAgainst`,
///   the `seen` the stamp was minted with and pinned beside) and the base holds that stamp too: the
///   writer edited exactly the version the server still has. That is what lets an edit made after
///   seeing a far-future stamp win (the mint gives it `clamp(seen) + 1 ms`, earlier than that stamp,
///   §6.3); between honest clocks it changes no outcome, since a minted stamp is later than what it
///   saw. Every path without that provenance goes by stamp order: a forwarded stub edit (§5.2),
///   pending fields re-applied to a moved copy (§6.2), a reconciling Mac's pending changes (§13.5),
///   a late-import patch, and each map or set element that has no provenance of its own.
///   A terminal value (`Card.status` `retired`) is never left: when one side holds it and the
///   other does not, it is the merged value whatever the stamps (§6.1).
/// - **S** server first: L wins only when the server has not moved the field since B (compare-and-set).
/// - **X**, **N**: the larger or smaller value (numbers; number arrays lexicographically; objects by
///   their `ord` array, taken whole), stamped with the later stamp; on a tie or when the values do not
///   compare, the server's value stays.
/// - **T** text body: L wins when the server has not moved the body since B; otherwise the server
///   stays and the field is listed in `needsTextMerge` for the three-way merge.
///
/// Maps and sets merge per key by the same rules. The result is idempotent (`merge(S, S, B) == S`),
/// and commutative in S and L for L, X and N fields and for elements. Vectors:
/// `schema/vectors/merge.json`; the JS port is `schema/js/merge.js`.
enum FieldMerge {
    struct Outcome: Equatable, Sendable {
        var merged: SyncEnvelope
        /// T fields both sides changed since the base, sorted.
        var needsTextMerge: [String]
        /// The S fields and elements where a different local value lost to the server's.
        var serverFirstLosses: [ServerFirstLoss]
        /// What M took from L (a value, or for X and N the later stamp), sorted. Every other local
        /// change lost; its outbox rows go.
        var takenFromLocal: [StampedPath]

        /// M is the server record and nothing local is still pending: the local side lost or was
        /// there already, and no body waits for its three-way merge (§6.2 steps 2 and 4).
        var isServerRecord: Bool { takenFromLocal.isEmpty && needsTextMerge.isEmpty }
    }

    /// A first write the local side lost (§6.2 step 2). `hook` is the type's `onServerFirstLoss`
    /// for the field, if it declares one (only `Card.kept`: `splitKeptCard`).
    struct ServerFirstLoss: Equatable, Sendable {
        let path: StampedPath
        let local: SyncJSON?
        let server: SyncJSON?
        let hook: String?
    }

    /// `mintedAgainst` holds, for each local path whose stamp this device minted and pinned, the
    /// stamp it was minted against (§6.3): the version of that field or element the writer saw. A
    /// path it does not list compares by stamp alone.
    static func merge(server: SyncEnvelope, local: SyncEnvelope, base: SyncEnvelope?,
                      mintedAgainst: [StampedPath: SyncStamp] = [:]) -> Outcome {
        var merged = server
        var needsTextMerge: [String] = []
        var losses: [ServerFirstLoss] = []
        var taken: [StampedPath] = []
        let spec = server.recordType?.spec
        let hooks = spec?.serverFirstLossHooks ?? [:]

        for field in local.stamps.keys.sorted() {
            let localStamp = local.stamps[field]!
            let baseStamp = base?.stamps[field]
            // The base's stamp means the writer did not change the field; the server's own stamp means
            // the local side holds exactly the server's write. Either way there is nothing to merge.
            if localStamp == baseStamp || localStamp == server.stamps[field] { continue }
            guard let serverStamp = server.stamps[field] else {
                merged.fields[field] = local.fields[field]
                merged.stamps[field] = localStamp
                taken.append(StampedPath(field))
                continue
            }
            switch (serverStamp, localStamp) {
            case (.value(let ss), .value(let ls)):
                let bs: SyncStamp? = if case .value(let stamp)? = baseStamp { stamp } else { nil }
                let decision = decide(ss, ls, bs, server.fields[field], local.fields[field],
                                      mintedAgainst: mintedAgainst[StampedPath(field)],
                                      terminalValues: spec?.field(field)?.terminalValues ?? [])
                apply(decision, to: &merged, field: field, local: local, localStamp: localStamp,
                      path: StampedPath(field), taken: &taken, needsTextMerge: &needsTextMerge)
                if decision == .serverLost, server.fields[field] != local.fields[field] {
                    losses.append(ServerFirstLoss(path: StampedPath(field), local: local.fields[field],
                                                  server: server.fields[field], hook: hooks[field]))
                }
            case (.elements(let serverElements), .elements(let localElements)):
                let baseElements: [String: SyncStamp] = if case .elements(let stamps)? = baseStamp { stamps } else { [:] }
                var values = server.fields[field]?.objectValue ?? [:]
                var stamps = serverElements
                let localValues = local.fields[field]?.objectValue ?? [:]
                for key in localElements.keys.sorted() {
                    let ls = localElements[key]!
                    let bs = baseElements[key]
                    if ls == bs || ls == serverElements[key] { continue }
                    let path = StampedPath(field, element: key)
                    guard let ss = serverElements[key] else {
                        values[key] = localValues[key]
                        stamps[key] = ls
                        taken.append(path)
                        continue
                    }
                    let decision = decide(ss, ls, bs, values[key], localValues[key],
                                          mintedAgainst: mintedAgainst[path], terminalValues: [])
                    switch decision {
                    case .takeLocal:
                        values[key] = localValues[key]
                        stamps[key] = ls
                        taken.append(path)
                    case .keepServer:
                        break
                    case .needsTextMerge:
                        // No schema field holds T per key; such an element keeps the server's, like S.
                        break
                    case .serverLost:
                        if values[key] != localValues[key] {
                            losses.append(ServerFirstLoss(path: path, local: localValues[key], server: values[key], hook: nil))
                        }
                    case .value(let value, let stamp):
                        if values[key] != value || stamps[key] != stamp {
                            values[key] = value
                            stamps[key] = stamp
                            taken.append(path)
                        }
                    }
                }
                merged.fields[field] = .object(values)
                merged.stamps[field] = .elements(stamps)
            default:
                // A scalar on one side and per-key stamps on the other: the server's shape is
                // the schema's (its letter wins the same way), so the local edit cannot be merged.
                continue
            }
        }
        return Outcome(merged: merged, needsTextMerge: needsTextMerge.sorted(), serverFirstLosses: losses,
                       takenFromLocal: taken.sorted { $0.description < $1.description })
    }

    // MARK: - One field or element

    private enum Decision: Equatable {
        case takeLocal
        case keepServer
        /// An S field the server moved since the base: the local value lost.
        case serverLost
        case needsTextMerge
        /// X or N: the winning value with the later stamp.
        case value(SyncJSON?, SyncStamp)
    }

    /// `mintedAgainst`: the stamp the local stamp was minted against, when the caller knows it.
    private static func decide(_ ss: SyncStamp, _ ls: SyncStamp, _ bs: SyncStamp?, _ serverValue: SyncJSON?,
                               _ localValue: SyncJSON?, mintedAgainst: SyncStamp?, terminalValues: [String]) -> Decision {
        let serverUnmoved = ss == bs
        switch ss.policy {
        case .lastWriter:
            let serverTerminal = serverValue?.stringValue.map(terminalValues.contains) ?? false
            let localTerminal = localValue?.stringValue.map(terminalValues.contains) ?? false
            if serverTerminal != localTerminal { return serverTerminal ? .keepServer : .takeLocal }
            let editedWhatTheServerHolds = serverUnmoved && mintedAgainst == ss
            return editedWhatTheServerHolds || ls.isLater(than: ss) ? .takeLocal : .keepServer
        case .serverFirst:
            return serverUnmoved ? .takeLocal : .serverLost
        case .textBody:
            return serverUnmoved ? .takeLocal : .needsTextMerge
        case .maximum, .minimum:
            let later = ls.isLater(than: ss) ? ls : ss
            guard let serverValue, let localValue, let order = compareOrdered(localValue, serverValue) else {
                return .value(serverValue, later)
            }
            let localWins = ss.policy == .maximum ? order > 0 : order < 0
            return .value(localWins ? localValue : serverValue, later)
        }
    }

    private static func apply(_ decision: Decision, to merged: inout SyncEnvelope, field: String, local: SyncEnvelope,
                              localStamp: SyncFieldStamp, path: StampedPath, taken: inout [StampedPath],
                              needsTextMerge: inout [String]) {
        switch decision {
        case .takeLocal:
            merged.fields[field] = local.fields[field]
            merged.stamps[field] = localStamp
            taken.append(path)
        case .keepServer, .serverLost:
            break
        case .needsTextMerge:
            needsTextMerge.append(field)
        case .value(let value, let stamp):
            if merged.fields[field] != value || merged.stamps[field] != .value(stamp) {
                merged.fields[field] = value
                merged.stamps[field] = .value(stamp)
                taken.append(path)
            }
        }
    }

    /// -1, 0 or 1 for two values X and N can order: numbers, arrays of numbers (lexicographically,
    /// a prefix first) or objects carrying an `ord` array of numbers; nil for anything else.
    static func compareOrdered(_ lhs: SyncJSON, _ rhs: SyncJSON) -> Int? {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case (.array(let a), .array(let b)):
            guard let a = numbers(a), let b = numbers(b) else { return nil }
            for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
            return a.count < b.count ? -1 : (a.count > b.count ? 1 : 0)
        case (.object(let a), .object(let b)):
            guard let ordA = a["ord"], let ordB = b["ord"], ordA.arrayValue != nil, ordB.arrayValue != nil else { return nil }
            return compareOrdered(ordA, ordB)
        default:
            return nil
        }
    }

    private static func numbers(_ values: [SyncJSON]) -> [Double]? {
        let numbers = values.compactMap(\.numberValue)
        return numbers.count == values.count ? numbers : nil
    }

    // MARK: - Compaction (§3.2 rule 4)

    /// The envelope with every removal marker older than the horizon dropped (a `null` map value or a
    /// `false` set element whose stamp's milliseconds are more than 90 days before `now`). The schema
    /// says which fields are maps and sets; a field it does not list, and every scalar, is left alone.
    static func compact(_ envelope: SyncEnvelope, now: Int64) -> SyncEnvelope {
        guard let spec = envelope.recordType?.spec else { return envelope }
        let horizon = now - Int64(SyncSchema.Limits.removalMarkerCompactionDays) * 86_400_000
        var compacted = envelope
        for (field, stamp) in envelope.stamps {
            guard case .elements(var stamps) = stamp, let kind = spec.field(field)?.kind, kind != .scalar,
                  var values = envelope.fields[field]?.objectValue
            else { continue }
            for (key, elementStamp) in stamps where elementStamp.milliseconds < horizon {
                let isMarker = kind == .map ? values[key] == .null : values[key] == .bool(false)
                if isMarker {
                    values.removeValue(forKey: key)
                    stamps.removeValue(forKey: key)
                }
            }
            compacted.fields[field] = .object(values)
            compacted.stamps[field] = .elements(stamps)
        }
        return compacted
    }
}

// MARK: - onServerFirstLoss hooks

enum ServerFirstLossHooks {
    /// `Card.kept` (§3.5.22): a Keep that lost to another device's Keep with a different
    /// `fingerprint` becomes a card of its own, so nothing the learner typed is lost. The new card is
    /// deterministic (`card:<deck>:split:<cardID>:<first 16 hex of sha256(fingerprint)>`), so a merge
    /// run twice over the same conflict makes one card. Nil when nothing was lost: the same
    /// fingerprint, or the same wording, or a lost Keep with no fingerprint to name the new card by.
    static func splitKeptCard(cardID: String, server: SyncEnvelope, lostKept: SyncJSON) -> RecordPatch? {
        guard let kept = lostKept.objectValue, let deck = server.fields["deckSourceID"]?.stringValue,
              let fingerprint = kept["fingerprint"]?.stringValue
        else { return nil }
        let serverKept = server.fields["kept"]
        if serverKept == lostKept || fingerprint == serverKept?["fingerprint"]?.stringValue { return nil }
        let seedKey = "split:\(cardID):" + SyncIdentity.sha256Hex(Data(fingerprint.utf8)).prefix(16)
        var changes: [String: RecordPatch.Change] = [
            "status": .value("kept"),
            "deckSourceID": .value(.string(deck)),
            "seedKey": .value(.string(seedKey)),
            "kept": .value(lostKept),
            "splitFrom": .value(.string(cardID)),
        ]
        for field in ["origin", "madeBy", "draftedAt", "legacy"] {
            if let value = server.fields[field] { changes[field] = .value(value) }
        }
        if let at = kept["at"] { changes["keptAt"] = .value(at) }
        return RecordPatch(.card, id: SyncIdentity.cardDraftID(deckSourceID: deck, seedKey: seedKey), changes: changes)
    }
}
