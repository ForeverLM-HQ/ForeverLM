import Foundation
@testable import ForeverLM

/// Anchors `Bundle(for:)` on the unit-test bundle, which carries `schema/vectors` as a folder
/// (`ForeverLMApp/project.yml`, docs/cloudkit-schema-design.md §12.1).
final class SyncVectorBundleAnchor {}

/// Runs the shared vectors (`schema/vectors/*.json`) through the sync core, case by case, and says
/// which failed and why. `SyncVectorConformanceTests` runs every file and each module's suite runs
/// its own; packages that cannot build compile this same file into a swiftc harness, so what the
/// harness proves is what the tests check. The JS core runs the same files (WP3).
enum SyncVectorRunner {
    struct Failure: CustomStringConvertible, Sendable {
        let file: String
        let name: String
        let detail: String
        var description: String { "\(file): \(name): \(detail)" }
    }

    struct Report: Sendable {
        var cases = 0
        var failures: [Failure] = []
    }

    /// Files whose implementation belongs to a later package: only their shape is checked here.
    static let pendingFiles: [String: String] = [
        "replica-audit": "WP5's ReplicaStore runs it",
    ]

    static let handledFiles: Set<String> = [
        "card-schedule", "chat-kind", "chat-ticks", "envelope", "fractional-index", "locator", "merge", "naming", "placement",
        "resolve", "stamp-clock", "text-merge", "url-normalize", "work-key",
    ]

    /// The vectors folder: the unit-test bundle's, or `FOREVERLM_SYNC_VECTORS` when a swiftc harness
    /// runs these suites outside a test bundle.
    static var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["FOREVERLM_SYNC_VECTORS"] { return URL(fileURLWithPath: path) }
        return Bundle(for: SyncVectorBundleAnchor.self).url(forResource: "vectors", withExtension: nil)
    }

    static func fileNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// `normalizeURL` is URL normalization v1 as the client runs it (the Mac passes its own); the
    /// vectors hold no local path. `textMerge` is the Mac's three-way merge, nil where it is absent.
    static func run(_ name: String, in directory: URL, normalizeURL: (String) -> String = defaultNormalizeURL,
                    textMerge: ((String, String, String) -> String?)? = nil) -> Report {
        var report = Report()
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url), let file = try? SyncJSON(parsing: data), let cases = file["cases"]?.arrayValue else {
            report.failures.append(Failure(file: name, name: "(file)", detail: "missing or not a vector file at \(url.path)"))
            return report
        }
        if file["format"]?.stringValue == nil || file["spec"]?.stringValue == nil || file["vectors"]?.stringValue != name {
            report.failures.append(Failure(file: name, name: "(file)", detail: "a vector file names itself, its spec and its format"))
        }
        for (index, entry) in cases.enumerated() {
            report.cases += 1
            let caseName = entry["name"]?.stringValue ?? "case \(index + 1)"
            do {
                if let detail = try check(name, entry, file: file, normalizeURL: normalizeURL, textMerge: textMerge) {
                    report.failures.append(Failure(file: name, name: caseName, detail: detail))
                }
            } catch {
                report.failures.append(Failure(file: name, name: caseName, detail: "threw \(error)"))
            }
        }
        return report
    }

    static let defaultNormalizeURL: (String) -> String = { input in
        URLNormalizer.normalize(input, localPath: { path in "<local path \(path) in the URL vectors>" })
    }

    private struct VectorError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - One case

    /// Nil when the case holds, else what differed.
    private static func check(_ name: String, _ entry: SyncJSON, file: SyncJSON, normalizeURL: (String) -> String,
                              textMerge: ((String, String, String) -> String?)?) throws -> String? {
        switch name {
        case "envelope": return try envelope(entry)
        case "merge": return try merge(entry)
        case "naming": return try naming(entry, file)
        case "fractional-index": return try fractionalIndex(entry)
        case "locator": return try locator(entry)
        case "work-key":
            return compare(WorkKey.normalizeRemote(try string(entry, "input")).map(SyncJSON.string) ?? .null, entry["expect"] ?? .null)
        case "url-normalize":
            let normalized = normalizeURL(try string(entry, "input"))
            if normalized != (try string(entry, "normalized")) { return "normalized to \(normalized)" }
            let id = SyncIdentity.sourceID(normalizedURL: normalized)
            return id == (try string(entry, "sourceID")) ? nil : "source id \(id)"
        case "resolve": return try resolve(entry)
        case "chat-ticks": return try chatTicks(entry)
        case "placement": return try placement(entry)
        case "stamp-clock": return try stampClock(entry)
        case "chat-kind": return try chatKind(entry)
        case "text-merge":
            guard let textMerge else { return nil }
            let merged = textMerge(try string(entry, "base"), try string(entry, "mine"), try string(entry, "theirs"))
            let got: SyncJSON = merged.map { ["merged": .string($0)] } ?? ["conflict": true]
            return compare(got, entry["expect"] ?? .null)
        case "card-schedule":
            // The fold from the case's offsets alone; `CardScheduleFoldTests` also checks each case
            // against today's scheduler in the case's zone.
            guard let input = entry["input"] else { throw VectorError(description: "input missing") }
            guard let output = CardScheduleFold.run(json: String(decoding: input.serialized(), as: UTF8.self)) else {
                return "the fold refused the input"
            }
            return compare(try SyncJSON(parsing: Data(output.utf8)), entry["expect"] ?? .null)
        case "replica-audit":
            let ok = entry["rows"]?.arrayValue != nil && entry["walk"]?["names"]?.arrayValue != nil && entry["expect"]?["delete"]?.arrayValue != nil
            return ok ? nil : "a replica-audit case has rows, walk.names and expect.delete"
        default:
            return "no runner for \(name).json: add it to SyncVectorRunner"
        }
    }

    // MARK: - envelope.json

    private static func envelope(_ entry: SyncJSON) throws -> String? {
        switch try string(entry, "op") {
        case "decode":
            guard let bytes = Data(base64Encoded: try string(entry, "bytesBase64")) else { throw VectorError(description: "bad base64") }
            let decoded: SyncEnvelope
            do {
                decoded = try SyncEnvelope(storedPayload: bytes)
            } catch let error as SyncEnvelopeError {
                guard let expected = entry["expectError"]?.stringValue else { return "refused: \(error)" }
                return errorName(error) == expected ? nil : "refused as \(errorName(error)), not \(expected)"
            }
            if let expected = entry["expectError"]?.stringValue { return "decoded, though \(expected) was expected" }
            if let summary = entry["expectSummary"] {
                let text = SyncGzip.isGzip(bytes) ? try SyncGzip.decompress(bytes, maxBytes: SyncSchema.Limits.payloadMaxInflatedBytes) : bytes
                var problems: [String] = []
                if decoded.type != summary["type"]?.stringValue || decoded.id != summary["id"]?.stringValue { problems.append("type or id") }
                if text.count != summary["decodedJSONBytes"]?.intValue { problems.append("decoded \(text.count) bytes") }
                if SyncIdentity.sha256Hex(text) != summary["decodedJSONSha256"]?.stringValue { problems.append("decoded sha256") }
                for (field, length) in summary["fieldLengths"]?.objectValue ?? [:] where decoded.fields[field]?.stringValue?.utf16.count != length.intValue {
                    problems.append("\(field) length")
                }
                return problems.isEmpty ? nil : problems.joined(separator: ", ")
            }
            if let spilled = entry["expectSpilled"], compare(.array(decoded.spilledFields.map(SyncJSON.string)), spilled) != nil {
                return "spilled fields \(decoded.spilledFields)"
            }
            return compare(decoded.json, entry["expect"] ?? .null)
        case "roundTrip":
            let original = entry["envelope"] ?? .null
            let decoded = try SyncEnvelope(storedPayload: try SyncEnvelope(json: original).storedPayload())
            return compare(decoded.json, original)
        case "storageForm":
            let form = SyncEnvelope.storageForm(jsonByteCount: try int(entry, "jsonBytes"))
            return (form == .gzip ? "gzip" : "plain") == (try string(entry, "expect")) ? nil : "stored \(form)"
        case "sizeCheck":
            let result: String
            do {
                try SyncEnvelope.checkStoredSize(try int(entry, "storedBytes"))
                result = "ok"
            } catch let error as SyncEnvelopeError {
                result = errorName(error)
            }
            return result == (try string(entry, "expect")) ? nil : "gave \(result)"
        case "stampValid":
            return (SyncStamp(try string(entry, "stamp")) != nil) == entry["expect"]?.boolValue ? nil : "validity differs"
        case "stampCompare":
            guard let a = SyncStamp(try string(entry, "a")), let b = SyncStamp(try string(entry, "b")) else { return "not stamps" }
            let order = SyncStamp.compare(a, b)
            return order == (try int(entry, "expect")) ? nil : "compared \(order)"
        case "spillDecision":
            let spills = SyncRecordType(rawValue: try string(entry, "type")).map {
                SyncEnvelope.spills(type: $0, field: (try? string(entry, "field")) ?? "", utf8Count: (try? int(entry, "utf8Bytes")) ?? 0)
            } ?? false
            return spills == entry["expect"]?.boolValue ? nil : "spills: \(spills)"
        case "cocoaToMs":
            guard let seconds = entry["cocoaSeconds"]?.numberValue else { throw VectorError(description: "cocoaSeconds") }
            let ms = SyncTime.milliseconds(cocoaSeconds: seconds)
            return ms == entry["expect"]?.int64Value ? nil : "gave \(ms)"
        case "msRoundTrip":
            guard let ms = entry["ms"]?.int64Value, let seconds = entry["cocoaSeconds"]?.numberValue else { throw VectorError(description: "ms") }
            let back = SyncTime.cocoaSeconds(milliseconds: ms)
            if back != seconds { return "ms gave \(back) seconds" }
            return SyncTime.milliseconds(cocoaSeconds: back) == ms ? nil : "seconds did not give the ms back"
        case "patch":
            return try patch(entry)
        default:
            return "unknown op"
        }
    }

    private static func patch(_ entry: SyncJSON) throws -> String? {
        guard let type = SyncRecordType(rawValue: try string(entry, "type")) else { throw VectorError(description: "type") }
        let id = try string(entry, "id")
        var held: SyncEnvelope
        if let raw = entry["held"], raw != .null {
            held = try SyncEnvelope(json: raw)
        } else {
            held = .new(type, id: id, saltID: try string(entry, "saltID"))
        }
        var changes: [String: RecordPatch.Change] = [:]
        for (field, change) in entry["changes"]?.objectValue ?? [:] {
            if let elements = change["elements"]?.objectValue {
                changes[field] = .elements(elements)
            } else {
                changes[field] = .value(change["value"] ?? .null)
            }
        }
        let stamps = entry["stamps"]?.objectValue ?? [:]
        var unexpected: [String] = []
        let stamped: [StampedPath]
        do {
            stamped = try held.apply(RecordPatch(type, id: id, changes: changes)) { path, _, _ in
                guard let text = stamps[path.description]?.stringValue, let stamp = SyncStamp(text) else {
                    unexpected.append(path.description)
                    return SyncStamp(policy: .lastWriter, milliseconds: 0, counter: 0, deviceID: "aaaaaaaa")
                }
                return stamp
            }
        } catch let error as RecordPatchError {
            guard let expected = entry["expectError"]?.stringValue else { return "refused: \(error)" }
            return patchErrorName(error) == expected ? nil : "refused as \(patchErrorName(error)), not \(expected)"
        }
        if let expected = entry["expectError"]?.stringValue { return "applied, though \(expected) was expected" }
        if !unexpected.isEmpty { return "stamped paths the case gives no stamp for: \(unexpected)" }
        if let mismatch = compare(.array(stamped.map { .string($0.description) }), entry["expectStamped"] ?? .null) {
            return "stamped \(stamped): \(mismatch)"
        }
        return compare(held.json, entry["expect"] ?? .null)
    }

    // MARK: - merge.json

    /// The case's partial records (`fields`, `stamps`, unknown keys) as envelopes of `type`.
    private static func partialEnvelope(_ value: SyncJSON, type: String) throws -> SyncEnvelope {
        guard var object = value.objectValue else { throw VectorError(description: "not a record") }
        object["env"] = SyncJSON(SyncSchema.envelopeVersion)
        object["type"] = .string(type)
        object["id"] = "vector-record"
        object["rev"] = SyncJSON(SyncSchema.schemaRevision)
        object["saltID"] = "00000000"
        if object["fields"] == nil { object["fields"] = [:] }
        if object["stamps"] == nil { object["stamps"] = [:] }
        return try SyncEnvelope(json: .object(object))
    }

    private static func partialJSON(_ envelope: SyncEnvelope) -> SyncJSON {
        var object = envelope.extra
        object["fields"] = .object(envelope.fields)
        object["stamps"] = envelope.json["stamps"]
        return .object(object)
    }

    private static func merge(_ entry: SyncJSON) throws -> String? {
        let type = entry["type"]?.stringValue ?? "VectorRecord"
        switch entry["op"]?.stringValue {
        case nil:
            let server = try partialEnvelope(entry["server"] ?? .null, type: type)
            let local = try partialEnvelope(entry["local"] ?? .null, type: type)
            let base = try entry["base"].flatMap { $0 == .null ? nil : try partialEnvelope($0, type: type) }
            var mintedAgainst: [StampedPath: SyncStamp] = [:]
            for path in entry["mintedAgainst"]?.arrayValue ?? [] {
                guard let stamp = SyncStamp(try string(path, "stamp")) else { throw VectorError(description: "mintedAgainst stamp") }
                mintedAgainst[StampedPath(try string(path, "field"), element: path["element"]?.stringValue)] = stamp
            }
            let outcome = FieldMerge.merge(server: server, local: local, base: base, mintedAgainst: mintedAgainst)
            var expected = entry["expect"]?.objectValue ?? [:]
            let expectedText = expected.removeValue(forKey: "needsTextMerge") ?? []
            if let mismatch = compare(partialJSON(outcome.merged), .object(expected)) { return mismatch }
            if let mismatch = compare(.array(outcome.needsTextMerge.map(SyncJSON.string)), expectedText) { return "needsTextMerge: \(mismatch)" }
            let losses: [SyncJSON] = outcome.serverFirstLosses.map { loss in
                var object: [String: SyncJSON] = ["field": .string(loss.path.field)]
                if let element = loss.path.element { object["element"] = .string(element) }
                if let hook = loss.hook { object["hook"] = .string(hook) }
                return .object(object)
            }
            return compare(.array(losses), entry["expectLosses"] ?? []).map { "losses: \($0)" }
        case "compact":
            let record = try partialEnvelope(entry["record"] ?? .null, type: type)
            return compare(partialJSON(FieldMerge.compact(record, now: try int64(entry, "now"))), entry["expect"] ?? .null)
        case "splitKeptCard":
            let server = try partialEnvelope(entry["server"] ?? .null, type: SyncRecordType.card.rawValue)
            let patch = ServerFirstLossHooks.splitKeptCard(cardID: try string(entry, "cardID"), server: server, lostKept: entry["lostKept"] ?? .null)
            let got: SyncJSON = patch.map { patch in
                var fields: [String: SyncJSON] = [:]
                for (field, change) in patch.changes {
                    if case .value(let value) = change { fields[field] = value }
                }
                return ["type": .string(patch.type.rawValue), "id": .string(patch.id), "fields": .object(fields)]
            } ?? .null
            return compare(got, entry["expect"] ?? .null)
        default:
            return "unknown op"
        }
    }

    // MARK: - naming.json

    private static func naming(_ entry: SyncJSON, _ file: SyncJSON) throws -> String? {
        let saltName = try string(entry, "salt")
        guard let saltText = file["salts"]?[saltName]?.stringValue, let salt = RecordNaming.salt(base64: saltText) else {
            return "salt \(saltName) is not 32 bytes of base64"
        }
        if let saltID = file["saltIDs"]?[saltName]?.stringValue, RecordNaming.saltID(salt) != saltID {
            return "saltID \(RecordNaming.saltID(salt))"
        }
        guard let type = SyncRecordType(rawValue: try string(entry, "type")) else { return "unknown type" }
        let id = try string(entry, "id")
        if let idFrom = entry["idFrom"] {
            let input = try string(idFrom, "input")
            let derived: String
            switch try string(idFrom, "rule") {
            case "SittingLegacyID": derived = SyncIdentity.sittingLegacyID(input)
            case "SourceFileID": derived = SyncIdentity.sourceFileID(sha256Hex: input)
            case "SourceURLID": derived = SyncIdentity.sourceID(normalizedURL: input)
            case "CollectionID":
                guard let colon = input.firstIndex(of: ":") else { return "CollectionID input without a kind" }
                derived = SyncIdentity.collectionID(kind: String(input[..<colon]), externalKey: String(input[input.index(after: colon)...]))
            default: return "unknown idFrom rule"
            }
            if derived != id { return "derived id \(derived)" }
        }
        let name = RecordNaming.recordName(type: type, id: id, salt: salt)
        if name != (try string(entry, "recordName")) { return "named \(name)" }
        return RecordNaming.recordType(ofRecordName: name) == type ? nil : "the name's prefix does not give the type back"
    }

    // MARK: - fractional-index.json

    private static func fractionalIndex(_ entry: SyncJSON) throws -> String? {
        let a = entry["a"]?.stringValue
        let b = entry["b"]?.stringValue
        do {
            let got: SyncJSON
            switch try string(entry, "op") {
            case "between": got = .string(try FractionalIndex.key(between: a, and: b))
            case "nBetween": got = .array(try FractionalIndex.keys(between: a, and: b, count: try int(entry, "n")).map(SyncJSON.string))
            default: return "unknown op"
            }
            if entry["expectError"]?.boolValue == true { return "gave \(got), though an error was expected" }
            return compare(got, entry["expect"] ?? .null)
        } catch is FractionalIndex.InvalidKey {
            return entry["expectError"]?.boolValue == true ? nil : "refused the keys"
        }
    }

    // MARK: - locator.json

    private static func locator(_ entry: SyncJSON) throws -> String? {
        switch try string(entry, "op") {
        case "roundTrip":
            let raw = entry["locator"] ?? .null
            guard let locator = Locator(json: raw) else { return "not read as a locator" }
            if let mismatch = compare(locator.value, raw) { return mismatch }
            let kind: String = if case .unknown = locator.kind { "unknown" } else { locator.kind.rawValue }
            if kind != (try string(entry, "expectKind")) { return "kind \(kind)" }
            return locator.isValid == entry["expectValid"]?.boolValue ? nil : "valid: \(locator.isValid)"
        case "parse":
            let isLocator = Locator(json: entry["input"] ?? .null) != nil
            return isLocator == entry["expectLocator"]?.boolValue ? nil : "is a locator: \(isLocator)"
        case "span":
            let raw = entry["span"] ?? .null
            let span = LocatorSpan(json: raw)
            if (span != nil) != entry["expectSpan"]?.boolValue { return "is a span: \(span != nil)" }
            guard let span else { return nil }
            if let mismatch = compare(span.value, raw) { return mismatch }
            return span.isValid == entry["expectValid"]?.boolValue ? nil : "valid: \(span.isValid)"
        default:
            return "unknown op"
        }
    }

    // MARK: - resolve.json

    private static func resolve(_ entry: SyncJSON) throws -> String? {
        switch try string(entry, "op") {
        case "resolveNotebook":
            let notebooks = entry["notebooks"]?.objectValue ?? [:]
            let redirects: (SyncRecordLocation) -> NotebookRedirects? = { location in
                guard let fields = notebooks[location.zone.name]?[location.id] else { return nil }
                return NotebookRedirects(mergedInto: fields["mergedInto"]?.stringValue, movedTo: fields["movedTo"]?.stringValue,
                                         movingTo: fields["movingTo"]?.stringValue)
            }
            guard let zone = SyncZoneName(try string(entry["start"] ?? .null, "zone")) else { return "bad start zone" }
            let resolved = NotebookResolution.resolve(SyncRecordLocation(zone: zone, id: try string(entry["start"] ?? .null, "id")), redirects: redirects)
            return compare(["zone": .string(resolved.zone.name), "id": .string(resolved.id)], entry["expect"] ?? .null)
        case "resolveSource":
            let sources = entry["sources"]?.objectValue ?? [:]
            let resolved = SourceResolution.resolve(try string(entry, "start")) { id in
                guard let fields = sources[id] else { return nil }
                return .some(fields["mergedInto"]?.stringValue)
            }
            return resolved == (try string(entry, "expect")) ? nil : "resolved to \(resolved)"
        default:
            return "unknown op"
        }
    }

    // MARK: - chat-ticks.json

    private static func chatTicks(_ entry: SyncJSON) throws -> String? {
        let entries = try (entry["entries"]?.arrayValue ?? []).map { raw -> SyncNotebookChatContext.Entry in
            guard let state = SyncStamp(try string(raw["stamps"] ?? .null, "state")) else { throw VectorError(description: "state stamp") }
            return SyncNotebookChatContext.Entry(
                containerID: try string(raw, "containerID"), itemKind: try string(raw, "itemKind"), itemID: try string(raw, "itemID"),
                state: try string(raw, "state"), approval: raw["approval"]?.stringValue, stateStamp: state,
                approvalStamp: raw["stamps"]?["approval"]?.stringValue.flatMap(SyncStamp.init))
        }
        // resolveNotebook() for an id, from the zone that holds it: Library first, then the spaces by name.
        let notebooks = entry["notebooks"]?.objectValue ?? [:]
        let redirects: (SyncRecordLocation) -> NotebookRedirects? = { location in
            guard let fields = notebooks[location.zone.name]?[location.id] else { return nil }
            return NotebookRedirects(mergedInto: fields["mergedInto"]?.stringValue, movedTo: fields["movedTo"]?.stringValue,
                                     movingTo: fields["movingTo"]?.stringValue)
        }
        let resolve: (String) -> String = { id in
            let zones = notebooks.keys.sorted { ($0 == SyncZone.library.rawValue ? 0 : 1, $0) < ($1 == SyncZone.library.rawValue ? 0 : 1, $1) }
            guard let held = zones.first(where: { notebooks[$0]?[id] != nil }), let zone = SyncZoneName(held) else { return id }
            return NotebookResolution.resolve(SyncRecordLocation(zone: zone, id: id), redirects: redirects).id
        }
        let notebookID = try string(entry, "notebookID")
        let excluded = entry["excluded"]?.objectValue ?? [:]
        let context = SyncNotebookChatContext.contextNotebookIDs(
            notebookID: notebookID, contextNotebooks: entry["contextNotebooks"]?.objectValue ?? [:],
            relatedNotebookIDs: entry["relatedNotebookIDs"]?.objectValue ?? [:], resolve: resolve)
        let ids = { (list: [String]) in SyncJSON.array(list.map(SyncJSON.string)) }
        if let expected = entry["expectContextNotebooks"], let failure = compare(ids(context), expected) {
            return "context notebooks: \(failure)"
        }
        let chat = SyncNotebookChatContext.chatSourceIDs(notebookID: notebookID, contextNotebookIDs: context, entries: entries, excluded: excluded)
        if let failure = compare(ids(chat), entry["expect"] ?? .null) { return "chat: \(failure)" }
        let studio = SyncNotebookChatContext.studioSourceIDs(notebookID: notebookID, entries: entries, excluded: excluded)
        if let failure = compare(ids(studio), entry["expectStudio"] ?? entry["expect"] ?? .null) { return "studio: \(failure)" }
        return nil
    }

    // MARK: - placement.json

    struct VectorReplica: ZonePlacementReplica {
        /// zone name → record type → id → fields.
        let records: [String: SyncJSON]

        func zones(holding type: SyncRecordType, id: String) -> [SyncZoneName] {
            records.compactMap { zone, types in types[type.rawValue]?[id] != nil ? SyncZoneName(zone) : nil }
        }

        func notebookRedirects(_ location: SyncRecordLocation) -> NotebookRedirects? {
            guard let fields = records[location.zone.name]?["Notebook"]?[location.id] else { return nil }
            return NotebookRedirects(mergedInto: fields["mergedInto"]?.stringValue, movedTo: fields["movedTo"]?.stringValue,
                                     movingTo: fields["movingTo"]?.stringValue)
        }

        func space(kind: String, primaryID: String) -> SyncZoneName? {
            records.keys.sorted().compactMap { zone -> SyncZoneName? in
                guard let name = SyncZoneName(zone), name.isSpace, let root = records[zone]?["ZoneRoot"]?["root"],
                      root["kind"]?.stringValue == kind, root["primaryID"]?.stringValue == primaryID
                else { return nil }
                return name
            }.first
        }
    }

    private static func placement(_ entry: SyncJSON) throws -> String? {
        guard let type = SyncRecordType(rawValue: try string(entry, "type")),
              let library = SyncZoneName(try string(entry, "writtenIn"))
        else { return "bad type or zone" }
        let zone = ZonePlacement.zone(for: type, id: try string(entry, "id"), fields: entry["fields"]?.objectValue ?? [:],
                                      writtenIn: library, replica: VectorReplica(records: entry["replica"]?.objectValue ?? [:]))
        return zone.name == (try string(entry, "expect")) ? nil : "placed in \(zone.name)"
    }

    // MARK: - stamp-clock.json

    private static func stampClock(_ entry: SyncJSON) throws -> String? {
        let samples = (entry["samples"]?.arrayValue ?? []).compactMap(\.int64Value)
        switch try string(entry, "op") {
        case "offset":
            let offset = StampClock(deviceID: "k3f7ab2q", offsetSamples: samples).serverOffset
            return compare(offset.map { SyncJSON($0) } ?? .null, entry["expect"] ?? .null)
        case "mint":
            guard let policy = SyncPolicy(rawValue: try string(entry, "policy")) else { return "policy" }
            var earlierCounters: [Int64: Int] = [:]
            for (key, counter) in entry["earlierCounters"]?.objectValue ?? [:] {
                guard let milliseconds = Int64(key), let counter = counter.intValue else { throw VectorError(description: "earlierCounters") }
                earlierCounters[milliseconds] = counter
            }
            var clock = StampClock(deviceID: try string(entry, "deviceID"), offsetSamples: samples,
                                   lastMilliseconds: try int64(entry, "lastMilliseconds"), lastCounter: try int(entry, "lastCounter"),
                                   earlierCounters: earlierCounters)
            let seen = entry["seen"]?.stringValue.flatMap(SyncStamp.init)
            let stamp = clock.mint(policy, eventTime: try int64(entry, "eventTime"), seen: seen, now: try int64(entry, "now"))
            if let mismatch = compare(stamp.map { .string($0.rawValue) } ?? .null, entry["expect"] ?? .null) { return mismatch }
            let earlier = SyncJSON.object(Dictionary(uniqueKeysWithValues: clock.earlierCounters.map { (String($0.key), SyncJSON($0.value)) }))
            let last: SyncJSON = ["lastMilliseconds": SyncJSON(clock.lastMilliseconds), "lastCounter": SyncJSON(clock.lastCounter),
                                  "earlierCounters": earlier]
            return compare(last, entry["expectLast"] ?? .null).map { "last stamp: \($0)" }
        default:
            return "unknown op"
        }
    }

    // MARK: - chat-kind.json

    private static func chatKind(_ entry: SyncJSON) throws -> String? {
        let evidence = entry["evidence"] ?? .null
        let flag: (String) -> Bool = { evidence[$0]?.boolValue ?? false }
        let kind = ChatKindClassifier.kind(of: ChatKindClassifier.Evidence(
            id: try string(evidence, "id"), kind: evidence["kind"]?.stringValue, isTeamSnapshot: flag("isTeamSnapshot"),
            isNamedByWalkthroughProgress: flag("isNamedByWalkthroughProgress"), holdsWalkthroughStep: flag("holdsWalkthroughStep"),
            hasOverallScore: flag("hasOverallScore"), hasCardIDs: flag("hasCardIDs"), hasGradedExchange: flag("hasGradedExchange")))
        return kind.rawValue == (try string(entry, "expect")) ? nil : "classified \(kind.rawValue)"
    }

    // MARK: - Helpers

    /// Nil when equal, else both sides as JSON.
    static func compare(_ got: SyncJSON, _ expected: SyncJSON) -> String? {
        got == expected ? nil : "got \(String(decoding: got.serialized(), as: UTF8.self)), expected \(String(decoding: expected.serialized(), as: UTF8.self))"
    }

    private static func string(_ value: SyncJSON, _ key: String) throws -> String {
        guard let text = value[key]?.stringValue else { throw VectorError(description: "\(key) missing") }
        return text
    }

    private static func int(_ value: SyncJSON, _ key: String) throws -> Int {
        guard let number = value[key]?.intValue else { throw VectorError(description: "\(key) missing") }
        return number
    }

    private static func int64(_ value: SyncJSON, _ key: String) throws -> Int64 {
        guard let number = value[key]?.int64Value else { throw VectorError(description: "\(key) missing") }
        return number
    }

    static func errorName(_ error: SyncEnvelopeError) -> String {
        switch error {
        case .notAnEnvelope: return "notAnEnvelope"
        case .unsupportedEnvelope: return "unsupportedEnvelope"
        case .invalidStamp: return "invalidStamp"
        case .payloadTooLarge: return "payloadTooLarge"
        }
    }

    static func patchErrorName(_ error: RecordPatchError) -> String {
        switch error {
        case .wrongRecord: return "wrongRecord"
        case .unknownField: return "unknownField"
        case .wrongKind: return "wrongKind"
        case .notASetElement: return "notASetElement"
        case .leavesTerminalValue: return "leavesTerminalValue"
        }
    }
}
