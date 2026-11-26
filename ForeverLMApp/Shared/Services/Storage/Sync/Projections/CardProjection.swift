import Foundation
import os

// MARK: - Card (docs/cloudkit-schema-design.md §3.5.22)

/// A card's local rows: its Memory item and anchors when it was kept (`memory_items`,
/// `memory_item_sources`, written once at Keep), and its state outside that wording
/// (`memory_card_states`): skipped or retired, seed, variants, "always ask it this way", a draft's wording.
struct CardRows: Equatable, Sendable {
    var item: MemoryItem?
    var state: State?
    /// The cards that take one point of this card's answer further (`memory_card_links`, the record's
    /// `details`), in their order.
    var details: [MemoryCardDetailLink] = []
    /// A source's wire id where it differs from the local id (a team's copy): the record names sources
    /// by wire id (§4.3), the rows by the id this Mac holds.
    var wireKeys: [String: String] = [:]

    func wireKey(_ sourceID: String) -> String { wireKeys[sourceID] ?? sourceID }

    struct State: Equatable, Sendable {
        var status: String
        var deckSourceID: String?
        var origin: String?
        var seedKey: String?
        var draft: SyncJSON?
        var kept: SyncJSON?
        var variants: [String: SyncJSON]
        var alwaysAsk: Bool
        var madeBy: SyncJSON?
        var draftedAt: Double?
        var skippedAt: Double?
        var retiredAt: Double?
        var supersedes: String?
        var splitFrom: String?
    }
}

/// The Card record's projection. The kept wording is S (never rewritten, D24): a card kept here is
/// encoded from its Memory item the same way every time, and one kept elsewhere is sent back exactly as
/// it came (`kept_json`), so this Mac never re-words a kept card. `retired` is terminal: an inbound card
/// never brings a retired item back, and the codec refuses to send a transition out of it. A losing
/// Keep becomes a card of its own through `onServerFirstLoss` (`recordLocalWrite`).
struct CardProjection: RecordProjection {
    var recordType: SyncRecordType { .card }

    static let itemColumns = ["kind", "target", "rubric_json", "learner_context", "goal_id", "status", "created_at", "idea_id"]
    static let anchorColumns = ["source_id", "locator_json", "excerpt", "source_sha256", "sort_index"]
    static let stateColumns = [
        "status", "deck_source_id", "origin", "seed_key", "draft_json", "kept_json", "variants_json", "always_ask",
        "made_by_json", "drafted_at", "skipped_at", "retired_at", "supersedes", "split_from",
    ]

    var tables: [ProjectedTable] {
        let itemSQL: @Sendable (String) -> String = { "\($0).memory_item_id" }
        return [
            .records("memory_items", type: .card, syncedColumns: Self.itemColumns),
            ProjectedTable(
                "memory_item_sources", localKey: ["id"], keyColumns: ["memory_item_id"], syncedColumns: Self.anchorColumns,
                recordTypes: [.card],
                record: { values in
                    values["memory_item_id"]?.textValue.map { RowRecord(type: .card, localID: $0, personalID: $0) }
                },
                localIDSQL: itemSQL, personalIDSQL: itemSQL
            ),
            .records("memory_card_states", type: .card, idColumn: "card_id", syncedColumns: Self.stateColumns),
            // A card's details: one map element of the overview's record per row, keyed by the detail's
            // id. No parent row is required: an overview is a draft (a state row) or a kept card (an item).
            ProjectedTable(
                "memory_card_links", localKey: ["parent_id", "child_id"], keyColumns: ["parent_id"],
                syncedColumns: Self.detailColumns, elementColumn: "child_id",
                recordTypes: [.card],
                record: { values in
                    values["parent_id"]?.textValue.map { RowRecord(type: .card, localID: $0, personalID: $0) }
                },
                localIDSQL: { "\($0).parent_id" }, personalIDSQL: { "\($0).parent_id" }
            ),
        ]
    }

    static let detailColumns = ["point", "sort_index", "linked_at"]

    private static func state(_ columns: [String]) -> FieldFeed { .columns(table: "memory_card_states", columns) }

    var feeds: [String: FieldFeed] {
        [
            "status": .anyOf([.columns(table: "memory_items", ["status"]), Self.state(["status"])]),
            "kept": .anyOf([
                .columns(table: "memory_items", ["kind", "target", "rubric_json", "learner_context", "goal_id", "created_at"]),
                .columns(table: "memory_item_sources", Self.anchorColumns), Self.state(["kept_json"]),
            ]),
            "legacy": .columns(table: "memory_items", ["kind", "target", "learner_context", "goal_id", "idea_id"]),
            "keptAt": .columns(table: "memory_items", ["created_at"]),
            "variants": Self.state(["variants_json"]),
            "alwaysAsk": Self.state(["always_ask"]),
            "draft": Self.state(["draft_json"]),
            "seedKey": Self.state(["seed_key"]),
            "skippedAt": Self.state(["skipped_at"]),
            "retiredAt": .anyOf([.columns(table: "memory_items", ["status"]), Self.state(["retired_at"])]),
            "details": .elementRows(table: "memory_card_links"),
        ]
    }

    /// A card is never deleted by a missing row: it is retired (§3.5.22).
    var missingRow: MissingRowOutcome { .fields([:]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> CardRows? {
        try Self.loadRows(id: record.localID, connection: connection)
    }

    static func loadRows(id: String, connection: SQLiteConnection) throws -> CardRows? {
        var item: MemoryItem?
        try connection.query("""
            SELECT kind, target, rubric_json, learner_context, goal_id, status, created_at, updated_at, idea_id
            FROM memory_items WHERE id = ?
        """, [.text(id)]) { row in
            item = MemoryItem(
                id: id, kind: row.text(0).flatMap(MemoryItemKind.init(rawValue:)) ?? .concept, target: row.text(1) ?? "",
                rubricJSON: row.text(2) ?? "{}", learnerContext: row.text(3), goalID: row.text(4),
                status: row.text(5).flatMap(MemoryItemStatus.init(rawValue:)) ?? .active, sources: [],
                createdAt: Date(timeIntervalSinceReferenceDate: row.real(6) ?? 0),
                updatedAt: Date(timeIntervalSinceReferenceDate: row.real(7) ?? 0), ideaID: row.text(8)
            )
        }
        if let found = item {
            var anchors: [MemoryItemSource] = []
            try connection.query("""
                SELECT id, source_id, locator_json, excerpt, source_sha256, sort_index FROM memory_item_sources
                WHERE memory_item_id = ? ORDER BY sort_index, id
            """, [.text(id)]) { row in
                anchors.append(MemoryItemSource(
                    id: row.text(0) ?? "", memoryItemID: id, sourceID: row.text(1) ?? "", locatorJSON: row.text(2),
                    excerpt: row.text(3) ?? "", sourceSHA256: row.text(4) ?? "", sortIndex: Int(row.integer(5) ?? 0)
                ))
            }
            item = found.replacingSources(anchors)
        }
        var state: CardRows.State?
        try connection.query("""
            SELECT status, deck_source_id, origin, seed_key, draft_json, kept_json, variants_json, always_ask, made_by_json,
                   drafted_at, skipped_at, retired_at, supersedes, split_from
            FROM memory_card_states WHERE card_id = ?
        """, [.text(id)]) { row in
            state = CardRows.State(
                status: row.text(0) ?? "kept", deckSourceID: row.text(1), origin: row.text(2), seedKey: row.text(3),
                draft: SittingProjection.json(row.text(4)), kept: SittingProjection.json(row.text(5)),
                variants: SittingProjection.json(row.text(6))?.objectValue ?? [:], alwaysAsk: row.integer(7) == 1,
                madeBy: SittingProjection.json(row.text(8)), draftedAt: row.real(9), skippedAt: row.real(10),
                retiredAt: row.real(11), supersedes: row.text(12), splitFrom: row.text(13)
            )
        }
        let details = try MemoryCardDetailLink.load(parentID: id, connection: connection)
        guard item != nil || state != nil || !details.isEmpty else { return nil }
        var rows = CardRows(item: item, state: state, details: details)
        if let store = connection as? KnowledgeStore {
            let ids = Set((item?.sources.map(\.sourceID) ?? []) + [state?.deckSourceID].compactMap { $0 })
            for source in ids {
                let key = try store.personalStateSourceKey(source)
                if key != source { rows.wireKeys[source] = key }
            }
        }
        return rows
    }

    /// The card's origin as `Card.origin` names it, from what this Mac recorded: the rubric's card origin,
    /// the seed it was drafted from, or, for an item from before cards, its kind (as the web reads one).
    static func origin(of item: MemoryItem, seedKey: String?) -> String {
        let rubric = (try? SyncJSON(parsing: Data(item.rubricJSON.utf8)))?["card"]?["origin"]?.stringValue
        switch rubric {
        case MemoryCardOrigin.walkthrough.rawValue?: return "walkthrough"
        case MemoryCardOrigin.courseQuiz.rawValue?: return "courseQuiz"
        case MemoryCardOrigin.assistant.rawValue?: return "assistant"
        case MemoryCardOrigin.manual.rawValue?: return "manual"
        case MemoryCardOrigin.drafted.rawValue?:
            return KnowledgeStore.draftedOrigin(seedKey: seedKey)
        default:
            return item.kind == .concept ? "concept" : "chat"
        }
    }

    /// The kept wording from the Memory item: the card's face when its rubric holds one (front, and the
    /// target as the back), else the target as the front (the web's reading); the rubric text as it is,
    /// since the curriculum fingerprint covers its bytes; the anchors in order, each with the id and place
    /// the fingerprint covers.
    static func kept(from item: MemoryItem, sourceKey: (String) -> String = { $0 }) -> SyncJSON {
        let face = (try? SyncJSON(parsing: Data(item.rubricJSON.utf8)))?["card"]?["front"]?.stringValue
        let anchors: [SyncJSON] = item.sources.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }.map { anchor in
            var object: [String: SyncJSON] = [
                "target": .string("src:" + sourceKey(anchor.sourceID)), "excerpt": .string(anchor.excerpt), "textHash": .string(anchor.sourceSHA256),
                "id": .string(anchor.id), "sortIndex": SyncJSON(anchor.sortIndex),
                "locator": anchor.locatorJSON.flatMap { try? SyncJSON(parsing: Data($0.utf8)) } ?? .null,
            ]
            if anchor.locatorJSON == nil { object["locator"] = .null }
            return .object(object)
        }
        return [
            "front": .string(face ?? item.target), "back": .string(face == nil ? "" : item.target), "rubric": .string(item.rubricJSON),
            "anchors": .array(anchors), "fingerprint": .string(MemoryTutorIdentity.immutableCurriculumFingerprint(item)),
            "at": SyncJSON(SyncTime.milliseconds(item.createdAt)),
        ]
    }

    static func encodeRows(_ rows: CardRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [:]
        let state = rows.state
        func ms(_ seconds: Double?) -> SyncJSON? { seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } }
        if let item = rows.item {
            let retired = item.status == .retired || state?.status == "retired"
            fields["status"] = .string(retired ? "retired" : "kept")
            fields["kept"] = state?.kept ?? kept(from: item, sourceKey: rows.wireKey)
            fields["keptAt"] = SyncJSON(SyncTime.milliseconds(item.createdAt))
            fields["legacy"] = [
                "kind": .string(item.kind.rawValue), "target": .string(item.target),
                "learnerContext": item.learnerContext.map(SyncJSON.string) ?? .null, "goalID": item.goalID.map(SyncJSON.string) ?? .null,
                "ideaID": item.ideaID.map(SyncJSON.string) ?? .null,
            ]
            let firstSource = item.sources.min { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }?.sourceID
            if let deck = state?.deckSourceID ?? firstSource { fields["deckSourceID"] = .string(rows.wireKey(deck)) }
            fields["origin"] = .string(state?.origin ?? origin(of: item, seedKey: state?.seedKey))
            if retired, let at = ms(state?.retiredAt) ?? ms(item.updatedAt.timeIntervalSinceReferenceDate) { fields["retiredAt"] = at }
        } else if let state {
            fields["status"] = .string(state.status)
            if let deck = state.deckSourceID { fields["deckSourceID"] = .string(rows.wireKey(deck)) }
            if let origin = state.origin { fields["origin"] = .string(origin) }
            if let kept = state.kept { fields["kept"] = kept }
            if let at = ms(state.retiredAt) { fields["retiredAt"] = at }
        }
        if let state {
            if let seed = state.seedKey { fields["seedKey"] = .string(seed) }
            if let draft = state.draft { fields["draft"] = draft }
            if !state.variants.isEmpty { fields["variants"] = .object(state.variants) }
            fields["alwaysAsk"] = .bool(state.alwaysAsk)
            if let madeBy = state.madeBy { fields["madeBy"] = madeBy }
            if let at = ms(state.draftedAt) { fields["draftedAt"] = at }
            if let at = ms(state.skippedAt) { fields["skippedAt"] = at }
            if let supersedes = state.supersedes { fields["supersedes"] = .string(supersedes) }
            if let splitFrom = state.splitFrom { fields["splitFrom"] = .string(splitFrom) }
        }
        // Always the field, an empty map too: a detail whose row was removed here is sent as removed
        // only while the field is encoded (`OutboxFeeder.diff`).
        var details: [String: SyncJSON] = [:]
        for detail in rows.details where details[detail.childID] == nil {
            details[detail.childID] = [
                "point": .string(detail.point), "order": SyncJSON(detail.order),
                "linkedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: detail.linkedAt)),
            ]
        }
        fields["details"] = .object(details)
        return fields
    }

    // MARK: Inbound

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // Per-member state: never in a space (D18).
        guard !record.zone.isSpace else { return .projected }
        try Self.applyFields(envelope.fields, id: record.localID, connection: connection)
        try Self.applyDetails(envelope.fields["details"], parentID: record.localID, connection: connection)
        return .projected
    }

    /// Each element of `details`: a live detail is written with its point and place, a removed one
    /// deleted. An element the record no longer lists (a removal marker compacted away) leaves its row
    /// alone, as every map fed by rows does. A detail naming its own card is dropped.
    static func applyDetails(_ value: SyncJSON?, parentID: String, connection: SQLiteConnection) throws {
        guard let elements = value?.objectValue else { return }
        for (childID, element) in elements.sorted(by: { $0.key < $1.key }) where !childID.isEmpty && childID != parentID {
            guard let object = element.objectValue else {
                try connection.execute(
                    "DELETE FROM memory_card_links WHERE parent_id = ? AND child_id = ?",
                    [.text(parentID), .text(childID)]
                )
                continue
            }
            try connection.execute("""
                INSERT INTO memory_card_links (parent_id, child_id, point, sort_index, linked_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(parent_id, child_id) DO UPDATE SET
                    point = excluded.point, sort_index = excluded.sort_index, linked_at = excluded.linked_at
            """, [
                .text(parentID), .text(childID), .text(object["point"]?.stringValue ?? ""),
                .integer(object["order"]?.int64Value ?? 0),
                .real(seconds(object["linkedAt"]) ?? Date().timeIntervalSinceReferenceDate),
            ])
        }
    }

    static func applyFields(_ fields: [String: SyncJSON], id: String, connection: SQLiteConnection) throws {
        let held = try loadRows(id: id, connection: connection)
        let status = fields["status"]?.stringValue ?? held?.state?.status ?? "kept"
        let kept = fields["kept"].flatMap { $0.isNull ? nil : $0 }
        let retired = status == "retired"

        if let item = held?.item {
            // The record's kept wording is the card's (S, the first acknowledged Keep): an item kept here
            // with other wording takes it, and this Mac's wording lives on in its own card (`splitFrom`,
            // made by the merge's `onServerFirstLoss`). Otherwise only retiring reaches the item, and
            // nothing brings it back.
            if let kept = kept?.objectValue, let fingerprint = kept["fingerprint"]?.stringValue,
               fingerprint != MemoryTutorIdentity.immutableCurriculumFingerprint(item) {
                try writeItem(id: id, kept: kept, fields: fields, retired: item.status == .retired || retired, replacing: true, connection: connection)
            }
            if retired, item.status != .retired {
                try connection.execute(
                    "UPDATE memory_items SET status = 'retired', updated_at = ? WHERE id = ?",
                    [.real(seconds(fields["retiredAt"]) ?? Date().timeIntervalSinceReferenceDate), .text(id)]
                )
            }
        } else if let kept = kept?.objectValue, status == "kept" || retired {
            try writeItem(id: id, kept: kept, fields: fields, retired: retired, replacing: false, connection: connection)
        }

        let variants = fields["variants"]?.objectValue.map { $0.filter { !$1.isNull } } ?? held?.state?.variants ?? [:]
        func text(_ field: String, _ held: String?) -> SQLiteValue {
            guard let given = fields[field] else { return .text(held) }
            return .text(given.stringValue)
        }
        func json(_ field: String, _ held: SyncJSON?) -> SQLiteValue {
            guard let given = fields[field] else { return .text(SittingProjection.text(held)) }
            return .text(SittingProjection.text(given))
        }
        func time(_ field: String, _ held: Double?) -> SQLiteValue {
            guard let given = fields[field] else { return .real(held) }
            return .real(seconds(given))
        }
        let heldState = held?.state
        // The terminal status stays: a card retired here is never kept again by an older record. An item
        // from before cards that this Mac's To Check still offers keeps saying so: its Card says `kept` on
        // every device (its item exists), and going through those items is this Mac's own.
        let stateStatus: String
        if heldState?.status == "retired" || held?.item?.status == .retired {
            stateStatus = "retired"
        } else if heldState?.status == "draft", held?.item != nil, status == "kept" {
            stateStatus = "draft"
        } else {
            stateStatus = status
        }
        try connection.execute("""
            INSERT INTO memory_card_states (card_id, status, deck_source_id, origin, seed_key, draft_json, kept_json, variants_json,
                always_ask, made_by_json, drafted_at, skipped_at, retired_at, supersedes, split_from)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(card_id) DO UPDATE SET
                status = excluded.status, deck_source_id = excluded.deck_source_id, origin = excluded.origin,
                seed_key = excluded.seed_key, draft_json = excluded.draft_json, kept_json = excluded.kept_json,
                variants_json = excluded.variants_json, always_ask = excluded.always_ask, made_by_json = excluded.made_by_json,
                drafted_at = excluded.drafted_at, skipped_at = excluded.skipped_at, retired_at = excluded.retired_at,
                supersedes = excluded.supersedes, split_from = excluded.split_from
        """, [
            .text(id), .text(stateStatus), text("deckSourceID", heldState?.deckSourceID), text("origin", heldState?.origin),
            text("seedKey", heldState?.seedKey), json("draft", heldState?.draft),
            // Kept wording as it came, so it goes back unchanged (S).
            .text(SittingProjection.text(kept ?? heldState?.kept)),
            .text(SittingProjection.text(.object(variants)) ?? "{}"),
            .integer((fields["alwaysAsk"]?.boolValue ?? heldState?.alwaysAsk ?? false) ? 1 : 0),
            json("madeBy", heldState?.madeBy), time("draftedAt", heldState?.draftedAt), time("skippedAt", heldState?.skippedAt),
            time("retiredAt", heldState?.retiredAt), text("supersedes", heldState?.supersedes), text("splitFrom", heldState?.splitFrom),
        ])
    }

    static func seconds(_ value: SyncJSON?) -> Double? {
        value?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
    }

    /// A card kept on another device as this Mac's Memory item: its wording from `kept` (the back when it has
    /// one, as a card's face does, else the front, which a card kept from a Memory item carries its target
    /// in), its other generation-1 columns from `legacy`, its anchors in order. `legacy.target` comes last: a
    /// lost Keep's own card (`splitKeptCard`) carries the winner's `legacy`.
    private static func writeItem(
        id: String, kept: [String: SyncJSON], fields: [String: SyncJSON], retired: Bool, replacing: Bool, connection: SQLiteConnection
    ) throws {
        let legacy = fields["legacy"]?.objectValue ?? [:]
        func clean(_ value: SyncJSON?) -> String? {
            guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return value?.stringValue
        }
        let front = clean(kept["front"]) ?? ""
        let target = clean(kept["back"]) ?? clean(kept["front"]) ?? clean(legacy["target"]) ?? ""
        let rubric = clean(kept["rubric"]) ?? String(decoding: SyncJSON.object([
            "card": ["cardID": .string(id), "front": .string(front), "origin": .string(fields["origin"]?.stringValue ?? "manual")],
            "criteria": .array([]),
        ]).serialized(), as: UTF8.self)
        let keptAt = seconds(fields["keptAt"]) ?? seconds(kept["at"]) ?? Date().timeIntervalSinceReferenceDate
        let kind = legacy["kind"]?.stringValue.flatMap(MemoryItemKind.init(rawValue:)) ?? .concept
        try connection.execute("""
            INSERT INTO memory_items (id, kind, target, rubric_json, learner_context, goal_id, status, created_at, updated_at, idea_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, target = excluded.target, rubric_json = excluded.rubric_json,
                learner_context = excluded.learner_context, goal_id = excluded.goal_id, idea_id = excluded.idea_id
        """, [
            .text(id), .text(kind.rawValue), .text(target), .text(rubric), .text(clean(legacy["learnerContext"])),
            .text(clean(legacy["goalID"])), .text(retired ? "retired" : "active"), .real(keptAt), .real(keptAt), .text(clean(legacy["ideaID"])),
        ])
        if replacing {
            try connection.execute("DELETE FROM memory_item_sources WHERE memory_item_id = ?", [.text(id)])
        }
        for (index, anchor) in (kept["anchors"]?.arrayValue ?? []).enumerated() {
            guard let object = anchor.objectValue else { continue }
            let target = object["target"]?.stringValue ?? ""
            let sourceID = target.hasPrefix("src:") ? String(target.dropFirst(4)).components(separatedBy: "#")[0] : (object["sourceID"]?.stringValue ?? target)
            try connection.execute("""
                INSERT INTO memory_item_sources (id, memory_item_id, source_id, locator_json, excerpt, source_sha256, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
            """, [
                .text(object["id"]?.stringValue ?? "\(id)#anchor-\(index)"), .text(id), .text(sourceID),
                .text(object["locator"].flatMap { $0.isNull ? nil : String(decoding: $0.serialized(), as: UTF8.self) }),
                .text(object["excerpt"]?.stringValue ?? ""), .text(object["textHash"]?.stringValue ?? ""),
                .integer(object["sortIndex"]?.int64Value ?? Int64(index)),
            ])
        }
        if let store = connection as? KnowledgeStore { try store.rebuildMemorySchedule(memoryItemID: id) }
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // A card is retired, not deleted: a deletion (a purge) takes only its state row; the Memory item and
        // its attempts stay generation-1 history. A draft is never taken by a deletion from another device:
        // the learner's own Skip is the only way a draft leaves To Check (product owner, 2026-10-30: "i never
        // want to lose draft flashcards unless I specifically say \"delete this one\"").
        guard !record.zone.isSpace else { return }
        try connection.execute("DELETE FROM memory_card_states WHERE card_id = ? AND status <> 'draft'", [.text(record.localID)])
    }
}

// MARK: - Deck state rows ↔ cards

extension KnowledgeStore {
    /// One deck's `cards.state.<deckID>` row as its cards' states (generation 2): a kept card's state under
    /// its Memory item's id, a skipped one under `card:<deckSourceID>:<seed>` when it has a seed, else its
    /// own card id; an item from before cards not gone through yet (its entry says draft and names the
    /// item, which "always ask" gave it) under its item's id, still `draft`. A deck card's draft wording is
    /// its deck's, which `deriveCardDrafts` writes. Variants are keyed by a hash of their words, so two
    /// devices adding the same rewording add one variant; an edited front is the variant `front`, and a
    /// card the day close reworded has the element `varied`.
    func mirrorCardDeckState(deckID: String, valuePlistXML: String) throws {
        guard let value = PreferenceStore.decodePlist(valuePlistXML),
              let deck = MemoryCardDeckState(preferenceValue: value)
        else { return }
        let deckSourceID = MemoryCard.sourceID(fromDraftDeckID: deckID)
        for (cardID, state) in deck.cards.sorted(by: { $0.key < $1.key }) where state.status != .draft || state.memoryItemID != nil {
            let id: String
            if state.status != .skipped, let item = state.memoryItemID {
                id = item
            } else if let deckSourceID, let seed = state.seed {
                id = SyncIdentity.cardDraftID(deckSourceID: deckSourceID, seedKey: seed)
            } else {
                id = cardID
            }
            let at = SyncTime.milliseconds(state.updatedAt)
            var variants: [String: SyncJSON] = [:]
            for text in state.variants {
                variants[Self.variantKey(text)] = ["text": .string(text), "madeAt": SyncJSON(at), "retired": false]
            }
            for text in state.retiredVariants {
                variants[Self.variantKey(text)] = ["text": .string(text), "madeAt": SyncJSON(at), "retired": true]
            }
            if let front = state.editedFront { variants["front"] = ["text": .string(front), "madeAt": SyncJSON(at), "retired": false] }
            if let face = state.editedFace { variants[MemoryCardFaceEdit.variantKey] = face.variantElement(at: at) }
            if let varied = state.variedAt {
                variants[Self.cardVariedVariantKey] = ["text": "", "madeAt": SyncJSON(SyncTime.milliseconds(varied)), "retired": true]
            }
            let skippedAt: Double? = state.status == .skipped ? state.updatedAt.timeIntervalSinceReferenceDate : nil
            let status = state.status.rawValue
            try execute("""
                INSERT INTO memory_card_states (card_id, status, deck_source_id, seed_key, variants_json, always_ask, skipped_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(card_id) DO UPDATE SET
                    status = CASE WHEN memory_card_states.status = 'retired' THEN 'retired'
                        WHEN excluded.status = 'draft' THEN memory_card_states.status ELSE excluded.status END,
                    deck_source_id = COALESCE(memory_card_states.deck_source_id, excluded.deck_source_id),
                    seed_key = COALESCE(excluded.seed_key, memory_card_states.seed_key),
                    variants_json = excluded.variants_json, always_ask = excluded.always_ask,
                    skipped_at = COALESCE(memory_card_states.skipped_at, excluded.skipped_at)
            """, [
                .text(id), .text(status), .text(deckSourceID), .text(state.seed),
                .text(SittingProjection.text(.object(variants)) ?? "{}"), .integer(state.alwaysAsk ? 1 : 0), .real(skippedAt),
            ])
        }
    }

    static func variantKey(_ text: String) -> String {
        "v" + SyncIdentity.sha256Hex(Data(text.utf8)).prefix(16)
    }

    /// Every deck's state row as its cards' states (§13.3 step 3c, `cards.state.*` → Card fields).
    func deriveCardStates() throws {
        var rows: [(key: String, xml: String)] = []
        try query(
            "SELECT key, value FROM user_preferences WHERE substr(key, 1, \(Prefs.Families.cardDeckState.prefix.count)) = ? ORDER BY key",
            [.text(Prefs.Families.cardDeckState.prefix)]
        ) { row in
            if let key = row.text(0), let xml = row.text(1) { rows.append((key, xml)) }
        }
        for row in rows {
            guard let deckID = MemoryCardDeckState.deckID(fromPreferenceKey: row.key) else { continue }
            try mirrorCardDeckState(deckID: deckID, valuePlistXML: row.xml)
        }
    }

    /// A record the merge made for a Keep this Mac lost (`onServerFirstLoss`, §6.2 step 2), written into the
    /// local rows inside the apply and marked as a local change, so the feeder sends it.
    func recordLocalWrite(_ patch: RecordPatch, registry: ProjectionRegistry = KnowledgeStore.projectionRegistry) throws {
        guard let projection = registry.projection(for: patch.type) else { return }
        var envelope = SyncEnvelope.new(patch.type, id: patch.id, saltID: "")
        var counter = 0
        _ = try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: 1, counter: counter, deviceID: SyncIdentity.migratedHistoryDeviceID)
        }
        let reference = ProjectionRecordRef(
            zoneKey: ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue), zone: .library,
            type: patch.type, wireID: patch.id, localID: patch.id
        )
        _ = try projection.apply(envelope, to: reference, connection: self)
        for table in projection.tables {
            try execute("""
                INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
                SELECT ?, \(OutboxTriggerSQL.localKey(table.localKey, "t")), '__row', ?
                FROM \(OutboxTriggerSQL.quoted(table.name)) AS t WHERE \(table.localIDSQL("t")) = ?
                ON CONFLICT(source_table, local_key, column) DO UPDATE SET dirty_at = excluded.dirty_at
            """, [.text(table.name), .real(Date().timeIntervalSinceReferenceDate), .text(patch.id)])
        }
    }
}

// MARK: - A card's pictures for the iPhone (`Card.pictures`)

/// The pictures on the learner's cards that a light client cannot draw from what it holds
/// (`CardPictureKey.isPublished`: a slide, a video frame, an article's or book's image, a stored drawing),
/// and the renderer the app hands the publisher. The Mac draws them from its own files, a video stream or its
/// image store; the iPhone holds none of those, so each is rendered here as a JPEG and uploaded with the card.
enum CardPictures {
    typealias Renderer = @Sendable (String) async -> Data?

    static let mime = "image/jpeg"
    /// Pictures rendered and uploaded in one pass after a round: a moment from a video is a capture over the
    /// network, so a backlog goes up a few dozen at a time rather than holding the drain for an hour.
    static let maximumPerRun = 40

    private static let registered = OSAllocatedUnfairLock<Renderer?>(initialState: nil)

    /// The app's renderer: a picture's address to its JPEG, nil when this Mac cannot draw it.
    static func register(_ renderer: @escaping Renderer) {
        registered.withLock { $0 = renderer }
    }

    static var renderer: Renderer? { registered.withLock { $0 } }

    /// Every picture address a card's stored face names, in order, once each.
    static func targets(inFaceJSON json: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        let pattern = #"foreverlm://image/[^"\\\s)]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = json as NSString
        for match in expression.matches(in: json, range: NSRange(location: 0, length: text.length)) {
            let target = text.substring(with: match.range)
            if seen.insert(target).inserted { found.append(target) }
        }
        return found
    }

    /// The learner's live cards (drafts and kept cards, newest first) with the published pictures their record
    /// does not point at yet. A card whose record is not in the replica yet waits for it: the pointer goes onto
    /// a held version.
    static func unpublished(connection: SQLiteConnection) throws -> [(cardID: String, targets: [String])] {
        var rows: [(cardID: String, json: String)] = []
        try connection.query("""
            SELECT card_id, COALESCE(kept_json, draft_json, '') FROM memory_card_states
            WHERE status IN ('draft', 'kept') AND COALESCE(kept_json, draft_json, '') LIKE '%foreverlm://image/%'
            ORDER BY COALESCE(drafted_at, 0) DESC, card_id
        """, []) { row in
            if let id = row.text(0), let json = row.text(1) { rows.append((id, json)) }
        }
        let replica = ReplicaStore(connection: connection)
        var cards: [(cardID: String, targets: [String])] = []
        for row in rows {
            let wanted = targets(inFaceJSON: row.json).filter { target in
                MemoryCardImage(target: target).map(CardPictureKey.isPublished) ?? false
            }
            guard !wanted.isEmpty,
                  let record = try replica.record(zoneKey: PrivateSyncZones.libraryKey, recordType: SyncRecordType.card.rawValue, wireID: row.cardID),
                  let envelope = try? SyncEnvelope(storedPayload: record.payload) else { continue }
            let held = envelope.fields["pictures"]?.objectValue ?? [:]
            let missing = wanted.filter { held[CardPictureKey.key($0)].flatMap(FileRef.init(json:)) == nil }
            if !missing.isEmpty { cards.append((row.cardID, missing)) }
        }
        return cards
    }
}

/// Renders and uploads the pictures of the learner's cards that the iPhone cannot draw itself, then points
/// each card's record at them (`Card.pictures[key]`): bytes before pointer (§3.5.30 rule 2), the pointers as
/// compare-and-set saves on the version the replica holds (`MaintenanceWriter`), as `BookCoverPublisher` does a
/// book's cover. A picture this Mac cannot render (its file and video are elsewhere) is tried three times a
/// launch; another Mac that holds it publishes it.
struct CardPicturePublisher {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CardPictures")
    private static let failures = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    let store: MacPrivateSyncStore
    let blobs: BlobStore
    let writer: MaintenanceWriter

    /// Returns the cards whose record now points at at least one more picture.
    @discardableResult
    func run() async -> Int {
        guard let render = CardPictures.renderer else { return 0 }
        do {
            let zones = try await store.perform { state -> (library: BlobZone, content: BlobZone)? in
                guard let library = try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: state),
                      let content = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state) else { return nil }
                return (library, content)
            }
            guard let zones else { return 0 }
            let failed = Self.failures.withLock { $0 }
            let cards = try await store.perform { try CardPictures.unpublished(connection: $0.connection) }
            guard !cards.isEmpty else { return 0 }

            var budget = CardPictures.maximumPerRun
            var writes: [MaintenanceWriter.Write] = []
            for card in cards where budget > 0 {
                var pointers: [String: SyncJSON] = [:]
                for target in card.targets where budget > 0 && (failed[Self.failureKey(card.cardID, target)] ?? 0) < 3 {
                    budget -= 1
                    guard let jpeg = await render(target) else {
                        Self.fail(card.cardID, target)
                        continue
                    }
                    let key = CardPictureKey.key(target)
                    do {
                        let file = try await blobs.upload(
                            jpeg, owner: card.cardID, ownerType: .card, role: CardPictureKey.role(key), mime: CardPictures.mime,
                            encoding: .identity, into: zones.content
                        )
                        pointers[key] = file.value
                    } catch {
                        if SourceFilePublisher.isTransient(error) { throw error }
                        Self.logger.error("A card picture did not upload: \(String(describing: error), privacy: .public)")
                        Self.fail(card.cardID, target)
                    }
                }
                guard !pointers.isEmpty else { continue }
                var patch = RecordPatch(.card, id: card.cardID)
                patch.changes["pictures"] = .elements(pointers)
                writes.append(MaintenanceWriter.Write(zone: zones.library, patch: patch, onlyIfHeld: true))
            }
            guard !writes.isEmpty else { return 0 }
            let outcomes = try await writer.save(writes)
            return outcomes.filter { $0 == .saved }.count
        } catch {
            Self.logger.notice("Publishing card pictures stopped for now: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func failureKey(_ cardID: String, _ target: String) -> String { cardID + "\n" + target }

    private static func fail(_ cardID: String, _ target: String) {
        failures.withLock { $0[failureKey(cardID, target), default: 0] += 1 }
    }
}

