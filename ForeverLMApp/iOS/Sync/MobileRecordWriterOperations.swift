import Foundation
import SQLite3

// The phone's library changes (docs/cloudkit-schema-design.md §5.2, §5.4, §5.6, §3.5.13–§3.5.28),
// each one `MobileWrite` transaction of RecordPatches, written the way the web's writer writes them,
// so every client makes the same records.

/// The keys the settings catalog lists under `leftOut` (§3.5.3, R7-m2): Settings only their own writer
/// sets, never `set_app_setting`. The phone's collection and notebook writers pass through it; a key it
/// does not list is refused. `MobileNotebookCollectionsStoreTests` holds it to
/// `schema/generated/settings-catalog.json`.
enum MobileSettingCatalog {
    struct LeftOut: Equatable, Sendable {
        let prefix: String
        let type: String
        let scopes: [String]
    }

    static let leftOut: [LeftOut] = [
        LeftOut(prefix: Prefs.Families.notebookNaming.prefix, type: "string", scopes: ["account"]),
        LeftOut(prefix: NotebookCollections.namePreferenceKeyPrefix, type: "string", scopes: ["account"]),
        // A saved workspace view is a Mac window arrangement; only the window that saves one writes it.
        LeftOut(prefix: "studio.workspaceView.", type: "array", scopes: ["account"]),
        // A notebook's kept suggested questions; the Mac's notebook chat writes them, the phone only reads.
        LeftOut(prefix: "notebook.questions.", type: "string", scopes: ["account"]),
        // The Map's layout; only the Mac's Map pane writes it.
        LeftOut(prefix: "map.layout.", type: "string", scopes: ["account"]),
        // The learner's grouping of pages in the Space (`PageSpaces`, `PagePins`, `PageParents`): a space's
        // name, the space a page is in, when it was pinned and the page it sits under, which the phone's
        // Space writes as the Mac's and the web's do (`MobileSpaceStore`).
        LeftOut(prefix: PageSpaces.namePreferenceKeyPrefix, type: "string", scopes: ["account"]),
        LeftOut(prefix: PageSpaces.membershipPreferenceKeyPrefix, type: "string", scopes: ["account"]),
        LeftOut(prefix: PagePins.preferenceKeyPrefix, type: "string", scopes: ["account"]),
        LeftOut(prefix: PageParents.preferenceKeyPrefix, type: "string", scopes: ["account"]),
        // A space in Trash (`PageSpaces`): the Mac's and the web's Space write it; the phone reads it,
        // leaving that space out of its sidebar.
        LeftOut(prefix: PageSpaces.trashPreferenceKeyPrefix, type: "string", scopes: ["account"]),
        // The learner's lists of goals and of ideas in the Space (`SpaceLists` on the Mac): a list's row and
        // the list a goal or an idea is in. Only the Mac's Space writes them so far.
        LeftOut(prefix: "spaceList.", type: "string", scopes: ["account"]),
        LeftOut(prefix: "spaceListItem.", type: "string", scopes: ["account"]),
        // A chat's pin (`ChatPins` on the Mac): Home's Pinned section on the Mac and the web. The phone
        // has no Pinned yet; it would write the row as they do.
        LeftOut(prefix: "chat.pinned.", type: "string", scopes: ["account"]),
        // The pages of a PDF the learner turned in the Mac's reader; the phone does not read it yet.
        LeftOut(prefix: "reader.pdfRotations.", type: "string", scopes: ["account"]),
        // That a task was given its starting model once for the account; only the Mac's Keychain seeding writes it.
        LeftOut(prefix: "aiSeeded.task.", type: "bool", scopes: ["account"]),
    ]

    static func leftOutEntry(for key: String) -> LeftOut? {
        leftOut.first { key.hasPrefix($0.prefix) && key.count > $0.prefix.count }
    }
}

/// Where a capture is filed (D47): the notebook it was added from, for the Job's `target` before the
/// first complete `Catalog` pass and the Entry after it.
struct MobileCaptureTarget: Equatable, Sendable {
    let notebookID: String
    /// How the source entered the notebook (`Entry.origin`): `added` from its Add sources, `share` from
    /// the share sheet.
    var origin = "added"
}

/// A chat as the phone records it (§3.5.13, §3.5.14): its kind is the creation site's (D50).
struct MobileChatRecord: Sendable {
    struct Exchange: Sendable {
        let id: String
        let seq: Int
        let question: String
        let userAnswer: String?
        let evaluation: String?
        let score: Double?
        let answeredAt: Date?
        let sourceRefs: [String]
        let knowledgeNote: String?
    }

    let id: String
    let kind: ChatKind
    let notebookID: String?
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let summary: String?
    let overallScore: Double?
    let sourceIDs: [String]
    let modelProvider: String
    let modelID: String
    let exchanges: [Exchange]
}

/// Where a notebook is asked to move (§5.3): a space the learner owns, or a new one.
enum MobileSpaceDestination: Equatable, Sendable {
    case space(String)
    case newSpace(kind: String, name: String)
}

extension MobileWrite {
    static let libraryKey = MobileProjection.libraryKey
    static let catalogKey = MobileProjection.catalogKey
    /// A Job waits a week after it is finished (§3.5.28).
    static let jobLifetime: Int64 = 7 * 86_400_000
    static let jobParamsMaxBytes = 16 * 1024

    // MARK: - Notebooks (§3.5.6, §5.2)

    /// A notebook in the personal library, under a new lowercase id.
    mutating func createNotebook(title: String, instructions: String?, summary: String?) throws -> String {
        let clean = MobileCloudMutationService.cleanTitle(title)
        guard !clean.isEmpty else { throw MobileRecordWriterError.emptyTitle }
        let id = newID()
        var patch = RecordPatch(.notebook, id: id)
        patch.changes["title"] = .value(.string(clean))
        patch.changes["status"] = .value(.string("active"))
        patch.changes["createdAt"] = .value(SyncJSON(milliseconds))
        if let instructions = MobileCloudMutationService.cleanInstructions(instructions) { patch.changes["instructions"] = .value(.string(instructions)) }
        if let summary = MobileCloudMutationService.cleanSummary(summary) { patch.changes["summary"] = .value(.string(summary)) }
        try write(patch, in: Self.libraryKey)
        return id
    }

    /// A rename, Instructions, the card's description or the status; nil leaves a field as it is, and
    /// `replace…` with nothing to keep clears it.
    mutating func updateNotebook(_ id: String, title: String? = nil, instructions: String? = nil, replaceInstructions: Bool = false,
                                 summary: String? = nil, replaceSummary: Bool = false, status: String? = nil) throws {
        let notebook = try liveNotebook(id)
        var patch = RecordPatch(.notebook, id: notebook.id)
        if let title {
            let clean = MobileCloudMutationService.cleanTitle(title)
            guard !clean.isEmpty else { throw MobileRecordWriterError.emptyTitle }
            patch.changes["title"] = .value(.string(clean))
        }
        if replaceInstructions {
            patch.changes["instructions"] = .value(MobileCloudMutationService.cleanInstructions(instructions).map(SyncJSON.string) ?? .null)
        }
        if replaceSummary {
            patch.changes["summary"] = .value(MobileCloudMutationService.cleanSummary(summary).map(SyncJSON.string) ?? .null)
        }
        if let status { patch.changes["status"] = .value(.string(status)) }
        try write(patch, in: notebook.zoneKey)
    }

    /// "Uses context from" (D52): `contextID` listed on the notebook, or no longer. Whether the
    /// member's chats read it is their own tick (`setContextNotebooks`).
    mutating func setRelatedNotebook(_ contextID: String, of id: String, linked: Bool) throws {
        let notebook = try liveNotebook(id)
        let context = (try? resolvedNotebook(contextID))?.id ?? contextID
        guard !context.isEmpty, context != notebook.id else { throw MobileRecordWriterError.notebookGone }
        if linked {
            let listed = (notebook.envelope.fields["relatedNotebookIDs"]?.objectValue ?? [:]).filter { $0.value == .bool(true) }
            guard listed.count < 50 || listed[context] != nil else { throw MobileRecordWriterError.refused("A notebook draws on at most 50 others.") }
        }
        var patch = RecordPatch(.notebook, id: notebook.id)
        patch.changes["relatedNotebookIDs"] = .elements([context: .bool(linked)])
        try write(patch, in: notebook.zoneKey)
    }

    /// Files sources into a notebook as approved members (§5.2 "Add a source"): one already there in
    /// any state or approval is made active and approved again, which ticks it for the member's chats
    /// through its new stamps (§5.6); a new one goes after the last. A space notebook gets the source
    /// copied in first when the space lacks it (§9.4). Returns the ids filed.
    @discardableResult
    mutating func fileSources(_ sourceIDs: [String], into id: String, origin: String = "added") throws -> [String] {
        let notebook = try liveNotebook(id)
        let entries = try entries(of: notebook)
        var keys = entries.map(\.orderKey)
        let person = try person(in: notebook.zoneKey)
        var filed: [String] = []
        for raw in sourceIDs {
            let sourceID = try sourceForFiling(raw, into: notebook)
            let entryID = SyncIdentity.entryID(containerID: notebook.id, itemKind: "source", itemID: sourceID)
            var patch = RecordPatch(.entry, id: entryID)
            if let held = entries.first(where: { $0.id == entryID }) {
                if held.state != "active" { patch.changes["state"] = .value(.string("active")) }
                if let approval = held.approval, approval != "approved" { patch.changes["approval"] = .value(.string("approved")) }
                if !patch.changes.isEmpty { try write(patch, in: notebook.zoneKey) }
            } else {
                let orderKey = try FractionalIndex.key(between: keys.max(), and: nil)
                keys.append(orderKey)
                patch.changes["containerKind"] = .value(.string("notebook"))
                patch.changes["containerID"] = .value(.string(notebook.id))
                patch.changes["itemKind"] = .value(.string("source"))
                patch.changes["itemID"] = .value(.string(sourceID))
                patch.changes["state"] = .value(.string("active"))
                patch.changes["approval"] = .value(.string("approved"))
                patch.changes["orderKey"] = .value(.string(orderKey))
                patch.changes["origin"] = .value(.string(origin))
                patch.changes["addedAt"] = .value(SyncJSON(milliseconds))
                if let person { patch.changes["addedBy"] = .value(person.value) }
                try write(patch, in: notebook.zoneKey)
            }
            filed.append(sourceID)
        }
        return filed
    }

    /// Takes sources out of a notebook: their Entries flip to `removed` (§5.2); never deleted.
    mutating func removeSources(_ sourceIDs: Set<String>, from id: String) throws {
        let notebook = try liveNotebook(id)
        for entry in try entries(of: notebook) where entry.itemKind == "source" && entry.state == "active" {
            guard sourceIDs.contains(entry.itemID) || sourceIDs.contains(where: { resolveSourceID($0, in: notebook) == entry.itemID }) else { continue }
            var patch = RecordPatch(.entry, id: entry.id)
            patch.changes["state"] = .value(.string("removed"))
            try write(patch, in: notebook.zoneKey)
        }
    }

    /// Deletes a notebook (§5.2) as the web does: the Notebook and its Notes Doc go; its chats, Docs
    /// and Goals are unfiled (or, asked, its chats deleted with their exchanges), and other notebooks
    /// stop listing it. Its Entries and the member's NotebookState are left: they flip and are never
    /// deleted (§6.4), and with the notebook gone they read as nothing. A course it follows is not its
    /// child (§5.5) and is not written: only the follow Entry goes with the notebook.
    mutating func deleteNotebook(_ id: String, deleteLinkedChats: Bool) throws {
        let notebook = try liveNotebook(id)
        let names: Set<String> = [notebook.id, id]
        try delete(.notebook, notebook.id, in: notebook.zoneKey)
        if try held(.artifact, "notes:\(notebook.id)", in: notebook.zoneKey) != nil {
            try delete(.artifact, "notes:\(notebook.id)", in: notebook.zoneKey)
        }
        for row in try rows("SELECT zone_key, id, notebook_id, linked_json FROM m_artifacts") where row[1] != "notes:\(notebook.id)" {
            var patch = RecordPatch(.artifact, id: row[1])
            if names.contains(row[2]) { patch.changes["notebookID"] = .value(.null) }
            let links = MobileReadModels.members(row[3]).filter(names.contains)
            if !links.isEmpty { patch.changes["linkedNotebookIDs"] = .elements(Dictionary(uniqueKeysWithValues: links.map { ($0, SyncJSON.bool(false)) })) }
            if !patch.changes.isEmpty { try write(patch, in: row[0]) }
        }
        for row in try rows("SELECT zone_key, id, notebook_id FROM m_chats") where names.contains(row[2]) {
            if deleteLinkedChats {
                try delete(.chat, row[1], in: row[0])
                for exchange in try rows("SELECT zone_key, id FROM m_exchanges WHERE zone_key = ? AND chat_id = ?", [.text(row[0]), .text(row[1])]) {
                    try delete(.exchange, exchange[1], in: exchange[0])
                }
            } else {
                var patch = RecordPatch(.chat, id: row[1])
                patch.changes["notebookID"] = .value(.null)
                try write(patch, in: row[0])
            }
        }
        for row in try rows("SELECT zone_key, id, notebook_id FROM m_goals") where names.contains(row[2]) {
            var patch = RecordPatch(.goal, id: row[1])
            patch.changes["notebookID"] = .value(.null)
            try write(patch, in: row[0])
        }
        for row in try rows("SELECT zone_key, id, related_json FROM m_notebooks") where row[1] != notebook.id {
            let links = MobileReadModels.members(row[2]).filter(names.contains)
            guard !links.isEmpty else { continue }
            var patch = RecordPatch(.notebook, id: row[1])
            patch.changes["relatedNotebookIDs"] = .elements(Dictionary(uniqueKeysWithValues: links.map { ($0, SyncJSON.bool(false)) }))
            try write(patch, in: row[0])
        }
        // The Schedule's tags naming it go too: a placement tagged with nothing
        // else stays as its source's automatic entry, or is released (`releasePlacement`).
        for row in try rows("SELECT source_id, goals_json FROM m_placements WHERE zone_key = ? AND state <> 'removed'", [.text(Self.libraryKey)]) {
            let tagged = MobileReadModels.members(row[1]).filter(names.contains)
            guard !tagged.isEmpty else { continue }
            try releasePlacement(row[0], goalIDs: tagged)
        }
    }

    /// Asks a Mac to move a notebook of the personal library into a space (§5.3, D21): a
    /// `Job(moveToSpace)`; a request already waiting for the notebook is answered instead of a second.
    mutating func requestMoveToSpace(_ id: String, to destination: MobileSpaceDestination) throws -> String {
        let notebook = try liveNotebook(id)
        guard notebook.isPersonal else { throw MobileRecordWriterError.refused("This notebook is already in a space.") }
        let params: SyncJSON
        switch destination {
        case .space(let spaceID):
            guard !spaceID.isEmpty else { throw MobileRecordWriterError.refused("Choose a space to move the notebook into.") }
            params = .object(["spaceID": .string(spaceID)])
        case .newSpace(let kind, let name):
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !clean.isEmpty else { throw MobileRecordWriterError.refused("Name the new space.") }
            params = .object(["newSpace": .object(["kind": .string(kind == "team" ? "team" : "notebook"), "name": .string(clean)])])
        }
        let target = "nb:\(notebook.id)"
        if let waiting = try jobs().first(where: { job in
            job.fields["kind"]?.stringValue == "moveToSpace" && job.fields["target"]?.stringValue == target
                && ["queued", "running"].contains(job.fields["status"]?.stringValue ?? "")
        }) {
            return waiting.id
        }
        return try writeJob("moveToSpace", target: target, params: params)
    }

    // MARK: - The member's NotebookState (§3.5.20, §5.6, D16, D52)

    /// The member's chat ticks of a notebook: the sources whose untick
    /// still names their compared Entry's stamps, and the context notebooks ticked in that the notebook
    /// still lists.
    func chatSelection(of id: String) throws -> NotebookChatContext.Selection {
        let notebook = try liveNotebook(id)
        let context = try chatContext(of: notebook)
        return NotebookChatContext.Selection(excluded: context.excluded, contextNotebookIDs: Set(context.ticked))
    }

    /// Writes the member's unticked sources: an untick names the Entry
    /// stamps the phone holds now (a pending change's included), a tick clears the element. Only
    /// elements that change are written.
    mutating func setChatExclusions(_ id: String, to wanted: Set<String>) throws {
        let notebook = try liveNotebook(id)
        let context = try chatContext(of: notebook)
        var changes: [String: SyncJSON] = [:]
        for sourceID in wanted where !context.excluded.contains(sourceID) {
            guard let entry = SyncNotebookChatContext.comparedEntry(for: sourceID, notebookID: notebook.id, contextNotebookIDs: context.ticked,
                                                                    entries: context.entries) else { continue }
            changes[sourceID] = .string(SyncNotebookChatContext.stampPair(entry))
        }
        for (sourceID, value) in context.rawExcluded where value != .null && !wanted.contains(sourceID) {
            changes[sourceID] = .null
        }
        guard !changes.isEmpty else { return }
        try writeNotebookState(notebook.id, field: "excluded", .elements(changes))
    }

    /// The context notebooks the member's chats draw on: exactly `wanted`, each resolved (§5.6).
    mutating func setContextNotebooks(_ id: String, to wanted: Set<String>) throws {
        let notebook = try liveNotebook(id)
        let resolved = Set(wanted.map { (try? resolvedNotebook($0))?.id ?? $0 })
        try writeNotebookStateSet(notebook.id, field: "contextNotebooks", to: resolved)
    }

    /// The member's Notebook Collections a notebook is in: exactly `wanted` (§3.5.20).
    mutating func setCollections(_ id: String, to wanted: Set<String>) throws {
        let notebook = try liveNotebook(id)
        try writeNotebookStateSet(notebook.id, field: "collections", to: wanted)
    }

    /// The Notebook Collections a notebook is in, as its NotebookState holds them.
    func collections(of id: String) throws -> [String] {
        let notebookID = (try? resolvedNotebook(id))?.id ?? id
        return members(try held(.notebookState, SyncIdentity.notebookStateID(notebookID: notebookID), in: Self.libraryKey)?.fields["collections"])
    }

    private mutating func writeNotebookStateSet(_ notebookID: String, field: String, to wanted: Set<String>) throws {
        let state = try held(.notebookState, SyncIdentity.notebookStateID(notebookID: notebookID), in: Self.libraryKey)
        let before = Set(members(state?.fields[field]))
        var changes: [String: SyncJSON] = [:]
        for id in wanted.subtracting(before) { changes[id] = .bool(true) }
        for id in before.subtracting(wanted) { changes[id] = .bool(false) }
        guard !changes.isEmpty else { return }
        try writeNotebookState(notebookID, field: field, .elements(changes))
    }

    private mutating func writeNotebookState(_ notebookID: String, field: String, _ change: RecordPatch.Change) throws {
        var patch = RecordPatch(.notebookState, id: SyncIdentity.notebookStateID(notebookID: notebookID))
        patch.changes["notebookID"] = .value(.string(notebookID))
        patch.changes[field] = change
        try write(patch, in: Self.libraryKey)
    }

    struct ChatContext {
        let ticked: [String]
        let entries: [SyncNotebookChatContext.Entry]
        let rawExcluded: [String: SyncJSON]
        let excluded: Set<String>
    }

    func chatContext(of notebook: Notebook) throws -> ChatContext {
        let state = try held(.notebookState, SyncIdentity.notebookStateID(notebookID: notebook.id), in: Self.libraryKey)
        let ticked = SyncNotebookChatContext.contextNotebookIDs(
            notebookID: notebook.id,
            contextNotebooks: state?.fields["contextNotebooks"]?.objectValue ?? [:],
            relatedNotebookIDs: notebook.envelope.fields["relatedNotebookIDs"]?.objectValue ?? [:],
            resolve: { (try? resolvedNotebook($0))?.id ?? $0 }
        )
        var entries = try self.entries(of: notebook).compactMap(\.tickEntry)
        for id in ticked {
            if let linked = try resolvedNotebook(id) { entries += try self.entries(of: linked).compactMap(\.tickEntry) }
        }
        let raw = state?.fields["excluded"]?.objectValue ?? [:]
        var excluded = Set<String>()
        for (sourceID, value) in raw {
            guard let pair = value.stringValue,
                  let entry = SyncNotebookChatContext.comparedEntry(for: sourceID, notebookID: notebook.id, contextNotebookIDs: ticked, entries: entries),
                  SyncNotebookChatContext.stampPair(entry) == pair else { continue }
            excluded.insert(sourceID)
        }
        return ChatContext(ticked: ticked, entries: entries, rawExcluded: raw, excluded: excluded)
    }

    /// A notebook's Entry as the index holds it (the pending patch laid over).
    struct HeldEntry {
        let id: String
        let itemKind: String
        let itemID: String
        let state: String
        let approval: String?
        let orderKey: String
        let tickEntry: SyncNotebookChatContext.Entry?
    }

    func entries(of notebook: Notebook) throws -> [HeldEntry] {
        var entries: [HeldEntry] = []
        try connection.query("""
            SELECT id, item_kind, item_id, state, approval, order_key, state_stamp, approval_stamp FROM m_entries
            WHERE zone_key = ? AND container_id = ? AND container_kind = 'notebook' ORDER BY order_key, id
        """, [.text(notebook.zoneKey), .text(notebook.id)]) { row in
            let itemKind = row.text(1) ?? ""
            let itemID = row.text(2) ?? ""
            let state = row.text(3) ?? ""
            let tick = row.text(6).flatMap(SyncStamp.init).map {
                SyncNotebookChatContext.Entry(containerID: notebook.id, itemKind: itemKind, itemID: itemID, state: state, approval: row.text(4),
                                              stateStamp: $0, approvalStamp: row.text(7).flatMap(SyncStamp.init))
            }
            entries.append(HeldEntry(id: row.text(0) ?? "", itemKind: itemKind, itemID: itemID, state: state, approval: row.text(4),
                                     orderKey: row.text(5) ?? "", tickEntry: tick))
        }
        return entries
    }

    // MARK: - Settings only their own writer sets (§3.5.3, R7-m2)

    /// A Notebook Collection's name or a notebook's naming mark, checked against the catalog's
    /// `leftOut` entry; nil clears it (Settings are never deleted).
    mutating func writeLeftOutSetting(_ key: String, _ value: String?) throws {
        guard let entry = MobileSettingCatalog.leftOutEntry(for: key), entry.type == "string", entry.scopes.contains("account") else {
            throw MobileRecordWriterError.refused("\"\(key)\" is not a setting ForeverLM keeps.")
        }
        var patch = RecordPatch(.setting, id: key)
        patch.changes["key"] = .value(.string(key))
        patch.changes["value"] = .value(value.map { .object(["t": .string("string"), "v": .string($0)]) } ?? .null)
        patch.changes["updatedBy"] = .value(.string(deviceID))
        try write(patch, in: Self.libraryKey)
    }

    /// A string Setting of the account as the phone holds it; nil when it is cleared or absent.
    func stringSetting(_ key: String) throws -> String? {
        guard let value = try held(.setting, key, in: Self.libraryKey)?.fields["value"], value["t"]?.stringValue == "string" else { return nil }
        return value["v"]?.stringValue
    }

    // MARK: - Reading (§3.5.18)

    /// Where the learner is in a source's text, as a fraction of it; nil before they have read it here.
    func readingFraction(of sourceID: String) throws -> Double? {
        let state = try held(.readingState, SyncIdentity.readingStateID(targetID: sourceID), in: Self.libraryKey)
        guard let locator = state?.fields["locator"], locator["t"]?.stringValue == "web" else { return nil }
        return locator["fraction"]?.numberValue
    }

    /// The Reader's place in a source (`ReadingState.locator`, `t: web`), its furthest point when it
    /// moved past it, and when it was last read. A place equal to the one held stamps nothing.
    mutating func saveReadingPosition(_ sourceID: String, fraction: Double) throws {
        let clamped = min(max(fraction, 0), 1)
        let id = SyncIdentity.readingStateID(targetID: sourceID)
        let state = try held(.readingState, id, in: Self.libraryKey)
        if let held = state?.fields["locator"], held["t"]?.stringValue == "web", let at = held["fraction"]?.numberValue, abs(at - clamped) < 0.0005 { return }
        var patch = readingStatePatch(id, sourceID: sourceID)
        patch.changes["locator"] = .value(.object(["t": .string("web"), "fraction": .number(clamped)]))
        patch.changes["lastReadAt"] = .value(SyncJSON(milliseconds))
        let furthest = state?.fields["furthest"]?.arrayValue?.compactMap(\.numberValue) ?? []
        if furthest.count == 2 ? clamped > furthest[1] : clamped > 0 {
            patch.changes["furthest"] = .value(.array([.number(furthest.first ?? 0), .number(clamped)]))
        }
        try write(patch, in: Self.libraryKey)
    }

    /// The learner reached the end of a source (`readAt`; for listening, `consumedAt` too). The first
    /// time stands.
    mutating func markRead(_ sourceID: String, at date: Date, consumed: Bool) throws {
        let id = SyncIdentity.readingStateID(targetID: sourceID)
        let state = try held(.readingState, id, in: Self.libraryKey)
        var patch = readingStatePatch(id, sourceID: sourceID)
        let at = SyncJSON(SyncTime.milliseconds(date))
        if state?.fields["readAt"].map({ $0 == .null }) ?? true { patch.changes["readAt"] = .value(at) }
        if consumed, state?.fields["consumedAt"].map({ $0 == .null }) ?? true { patch.changes["consumedAt"] = .value(at) }
        guard patch.changes.count > 2 else { return }
        patch.changes["lastReadAt"] = .value(at)
        try write(patch, in: Self.libraryKey)
    }

    private func readingStatePatch(_ id: String, sourceID: String) -> RecordPatch {
        var patch = RecordPatch(.readingState, id: id)
        patch.changes["targetKind"] = .value(.string("source"))
        patch.changes["targetID"] = .value(.string(sourceID))
        return patch
    }

    // MARK: - Chats (§3.5.13, §3.5.14, D19, D50)

    /// A chat and one Exchange per turn the phone recorded, with the kind its creation site gives. A
    /// private kind stays in the member's `Library` wherever it is filed (D19); an ordinary chat goes to
    /// its notebook's zone. Exchanges are written once (S): a turn saved again unchanged writes nothing.
    mutating func recordChat(_ chat: MobileChatRecord) throws {
        let existing = try zoneKeys(holding: .chat, chat.id).first
        let notebook = try chat.notebookID.flatMap { try resolvedNotebook($0) }
        let zoneKey = try existing ?? zoneKey(for: .chat, id: chat.id, fields: [
            "kind": .string(chat.kind.rawValue), "notebookID": notebook.map { .string($0.id) } ?? .null,
        ])
        let held = try held(.chat, chat.id, in: zoneKey)
        let kind = held?.fields["kind"]?.stringValue.flatMap(ChatKind.init(rawValue:)) ?? chat.kind
        let person = try person(in: zoneKey)
        var patch = RecordPatch(.chat, id: chat.id)
        if held == nil {
            patch.changes["kind"] = .value(.string(kind.rawValue))
            patch.changes["createdAt"] = .value(SyncJSON(SyncTime.milliseconds(chat.startedAt)))
            if let person { patch.changes["createdBy"] = .value(person.value) }
        }
        patch.changes["notebookID"] = .value(notebook.map { .string($0.id) } ?? .null)
        patch.changes["title"] = .value(.string(chat.title))
        patch.changes["status"] = .value(.string(chat.endedAt == nil ? "active" : "ended"))
        let sourceIDs = chat.sourceIDs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        patch.changes["contextMode"] = .value(.string(!sourceIDs.isEmpty ? "explicit" : notebook != nil ? "notebook" : "none"))
        let heldSources = Set(members(held?.fields["contextSourceIDs"]))
        var contextDiff: [String: SyncJSON] = [:]
        for id in Set(sourceIDs).subtracting(heldSources) { contextDiff[id] = .bool(true) }
        for id in heldSources.subtracting(sourceIDs) { contextDiff[id] = .bool(false) }
        if !contextDiff.isEmpty { patch.changes["contextSourceIDs"] = .elements(contextDiff) }
        if let summary = chat.summary { patch.changes["summary"] = .value(.string(summary)) }
        if kind.isPrivate, let score = chat.overallScore { patch.changes["overallScore"] = .value(.number(score)) }
        if !chat.modelID.isEmpty { patch.changes["model"] = .value(.object(["provider": .string(chat.modelProvider), "id": .string(chat.modelID)])) }
        let answered = chat.exchanges.compactMap(\.answeredAt).map(SyncTime.milliseconds)
        patch.changes["editedAt"] = .value(SyncJSON(([SyncTime.milliseconds(chat.startedAt)] + answered + [chat.endedAt.map(SyncTime.milliseconds) ?? 0]).max()!))
        try write(patch, in: zoneKey)
        for exchange in chat.exchanges {
            try writeExchange(exchange, chatID: chat.id, startedAt: chat.startedAt, privateKind: kind.isPrivate, person: person, in: zoneKey)
        }
    }

    /// A continued chat's turns (§3.5.14): new Exchanges after the highest `seq` the phone holds, so two
    /// devices appending at once both survive. A turn already written keeps its record; the chat's
    /// `editedAt` (X) moves to the newest turn, and nothing else of it is rewritten.
    mutating func appendExchanges(_ exchanges: [MobileNotebookChatContinuation.AddedExchange], toChat chatID: String,
                                  knowledgeNote: String, modelProvider: String, modelID: String, endedAt: Date) throws {
        guard !exchanges.isEmpty else { return }
        guard let zoneKey = try zoneKeys(holding: .chat, chatID).first, let chat = try held(.chat, chatID, in: zoneKey) else {
            throw MobileRecordWriterError.chatGone
        }
        let kind = chat.fields["kind"]?.stringValue.flatMap(ChatKind.init(rawValue:)) ?? .chat
        var written = Set<String>()
        var seq = 0
        for row in try rows("SELECT id, seq FROM m_exchanges WHERE zone_key = ? AND chat_id = ?", [.text(zoneKey), .text(chatID)]) {
            written.insert(row[0])
            seq = max(seq, Int(row[1]) ?? 0)
        }
        let person = try person(in: zoneKey)
        let startedAt = chat.fields["createdAt"]?.int64Value.map(SyncTime.date(milliseconds:)) ?? endedAt
        var newest = endedAt
        for added in exchanges where !written.contains(added.id) {
            seq += 1
            newest = max(newest, added.answeredAt)
            try writeExchange(MobileChatRecord.Exchange(id: added.id, seq: seq, question: "", userAnswer: added.userAnswer, evaluation: added.evaluation,
                                                        score: nil, answeredAt: added.answeredAt, sourceRefs: [], knowledgeNote: knowledgeNote),
                              chatID: chatID, startedAt: startedAt, privateKind: kind.isPrivate, person: person, in: zoneKey, model: (modelProvider, modelID))
        }
        var patch = RecordPatch(.chat, id: chatID)
        patch.changes["editedAt"] = .value(SyncJSON(SyncTime.milliseconds(newest)))
        try write(patch, in: zoneKey, edited: false)
    }

    private mutating func writeExchange(_ exchange: MobileChatRecord.Exchange, chatID: String, startedAt: Date, privateKind: Bool, person: SyncPerson?,
                                        in zoneKey: String, model: (provider: String, id: String)? = nil) throws {
        let answer = exchange.userAnswer.flatMap { $0.isEmpty ? nil : $0 }
        guard !exchange.question.isEmpty || answer != nil || exchange.evaluation != nil else { return }
        var patch = RecordPatch(.exchange, id: exchange.id)
        patch.changes["chatID"] = .value(.string(chatID))
        patch.changes["seq"] = .value(SyncJSON(exchange.seq))
        patch.changes["createdAt"] = .value(SyncJSON(SyncTime.milliseconds(exchange.answeredAt ?? startedAt)))
        patch.changes["question"] = .value(.string(exchange.question))
        if let answer { patch.changes["userAnswer"] = .value(.string(answer)) }
        if let evaluation = exchange.evaluation { patch.changes["evaluation"] = .value(.string(evaluation)) }
        if privateKind, let score = exchange.score { patch.changes["score"] = .value(.number(score)) }
        if !exchange.sourceRefs.isEmpty { patch.changes["sourceRefs"] = .value(.array(exchange.sourceRefs.map(SyncJSON.string))) }
        if let note = exchange.knowledgeNote, !note.isEmpty { patch.changes["knowledgeNote"] = .value(.string(note)) }
        if let answeredAt = exchange.answeredAt { patch.changes["answeredAt"] = .value(SyncJSON(SyncTime.milliseconds(answeredAt))) }
        if let model, !model.id.isEmpty { patch.changes["model"] = .value(.object(["provider": .string(model.provider), "id": .string(model.id)])) }
        if let person { patch.changes["author"] = .value(person.value) }
        try write(patch, in: zoneKey)
    }

    // MARK: - Jobs (§3.5.28)

    /// A Job for work only a Mac does, queued in the member's `Library`, expiring a week after it is
    /// finished. `params` is at most 16 KiB.
    mutating func writeJob(_ kind: String, target: String?, params: SyncJSON) throws -> String {
        guard params.serialized().count <= Self.jobParamsMaxBytes else { throw MobileRecordWriterError.tooLarge }
        let id = newID()
        var patch = RecordPatch(.job, id: id)
        patch.changes["kind"] = .value(.string(kind))
        if let target { patch.changes["target"] = .value(.string(target)) }
        patch.changes["params"] = .value(params)
        patch.changes["requestedBy"] = .value(.object(["device": .string(deviceID), "platform": .string("ios")]))
        patch.changes["requestedAt"] = .value(SyncJSON(milliseconds))
        patch.changes["status"] = .value(.string("queued"))
        patch.changes["expiresAt"] = .value(SyncJSON(milliseconds + Self.jobLifetime))
        try write(patch, in: Self.libraryKey)
        return id
    }

    /// The Jobs of the member's `Library` the phone holds, decoded (they are few, and expire).
    func jobs() throws -> [SyncEnvelope] {
        try zoneKeysAndIDs(of: .job).compactMap { zoneKey, id in zoneKey == Self.libraryKey ? try held(.job, id, in: zoneKey) : nil }
    }

    // MARK: - Captures (§4.2, §5.4, D47)

    /// A web page captured on the phone. Before the first complete `Catalog` pass, or for an address
    /// only a Mac can normalize, it is a `Job(ingestURL)` with its filing target only. After it, a
    /// source the library holds under the address's id is taken back (unarchived, its dismissal
    /// cleared); any other is a skeletal Source with a `Job(ingestURL)` a Mac fetches. Either way it is
    /// filed into `target` when that notebook is still there. Returns the source's id, nil when only a
    /// Mac can mint it.
    mutating func captureURL(_ url: URL, title: String?, sourceType: String, target: MobileCaptureTarget?) throws -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw MobileCloudMutationError.unsupportedCaptureURL
        }
        if let label = MobileCloudMutationService.linkedPageKindLabel(for: url) { throw MobileCloudMutationError.linkedPage(label) }
        let notebook = target.flatMap { try? liveNotebook($0.notebookID) }
        let key = WorkKey.normalizeRemote("url:\(url.absoluteString)")
        var params: [String: SyncJSON] = ["url": .string(url.absoluteString), "workKeys": .array(key.map { [.string($0)] } ?? [])]
        if let notebook { params["target"] = Self.jobTarget(notebook) }
        guard let key, try catalogPassed else {
            _ = try writeJob("ingestURL", target: nil, params: .object(params))
            return key.map { SyncIdentity.sourceID(normalizedURL: String($0.dropFirst(4))) }
        }
        let id = SyncIdentity.sourceID(normalizedURL: String(key.dropFirst(4)))
        try clearDismissals(workKeys: [key])
        if let held = try held(.source, id, in: Self.catalogKey) {
            if held.fields["status"]?.stringValue == "archived" {
                var patch = RecordPatch(.source, id: id)
                patch.changes["status"] = .value(.string("active"))
                try write(patch, in: Self.catalogKey)
            }
        } else {
            let type = ["paper", "podcast", "video"].contains(sourceType.lowercased()) ? sourceType.lowercased() : "article"
            let clean = title.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) } ?? ""
            try writeSkeleton(id, primaryKey: key, title: clean.isEmpty ? url.absoluteString : clean, type: type, url: url.absoluteString, pdf: nil)
            _ = try writeJob("ingestURL", target: "src:\(id)", params: .object(params))
        }
        if let notebook, let target { try fileSources([id], into: notebook.id, origin: target.origin) }
        return id
    }

    /// A PDF captured on the phone whose `pdf` satellites are already uploaded and acknowledged (`file`,
    /// owned by `SourceIdentity.fileID`, D47): a `Job(ingestFile)` with its filing target before the
    /// first complete `Catalog` pass; after it, a skeletal Source holding `files.pdf`, its Job, and the
    /// Entry into `target`.
    mutating func captureFile(_ file: FileRef, sha256: String, title: String, capture: String, target: MobileCaptureTarget?) throws -> String {
        let id = SyncIdentity.sourceFileID(sha256Hex: sha256)
        let notebook = target.flatMap { try? liveNotebook($0.notebookID) }
        var params: [String: SyncJSON] = ["file": file.value, "sha256": .string(sha256), "title": .string(title), "capture": .string(capture)]
        if let notebook { params["target"] = Self.jobTarget(notebook) }
        guard try catalogPassed else {
            _ = try writeJob("ingestFile", target: nil, params: .object(params))
            return id
        }
        let key = "file:\(sha256)"
        try clearDismissals(workKeys: [key])
        if let held = try held(.source, id, in: Self.catalogKey) {
            if held.fields["status"]?.stringValue == "archived" {
                var patch = RecordPatch(.source, id: id)
                patch.changes["status"] = .value(.string("active"))
                try write(patch, in: Self.catalogKey)
            }
        } else {
            try writeSkeleton(id, primaryKey: key, title: title, type: "paper", url: nil, pdf: file)
            _ = try writeJob("ingestFile", target: "src:\(id)", params: .object(params))
        }
        if let notebook, let target { try fileSources([id], into: notebook.id, origin: target.origin) }
        return id
    }

    static func jobTarget(_ notebook: Notebook) -> SyncJSON {
        .object(["notebookID": .string(notebook.id), "approval": .string("approved")])
    }

    /// A Source's create-safe fields (§5.4, `SourceSkeleton`) and the member's own provenance Mark.
    private mutating func writeSkeleton(_ id: String, primaryKey: String, title: String, type: String, url: String?, pdf: FileRef?) throws {
        let patch = SourceSkeleton.patch(id: id, primaryKey: primaryKey, workKeys: [primaryKey], title: title, type: type, url: url,
                                         madeBy: MadeBy(route: "ios", device: deviceID, at: milliseconds), addedAt: milliseconds, pdf: pdf)
        try write(patch, in: Self.catalogKey, provisional: SourceSkeleton.provisionalFields.union(["status"]))
        try writeMark("provenance", target: "src:\(id)", on: true, value: .object(["origin": .string("manual"), "at": SyncJSON(milliseconds)]))
    }

    /// The member's Mark of `kind` on `target` (`mk:<kind>:<target>`), flipped, never deleted.
    mutating func writeMark(_ kind: String, target: String, on: Bool, value: SyncJSON? = nil) throws {
        var patch = RecordPatch(.mark, id: SyncIdentity.markID(kind: kind, target: target))
        patch.changes["kind"] = .value(.string(kind))
        patch.changes["target"] = .value(.string(target))
        patch.changes["on"] = .value(.bool(on))
        if let value { patch.changes["value"] = .value(value) }
        patch.changes["at"] = .value(SyncJSON(milliseconds))
        try write(patch, in: Self.libraryKey)
    }

    /// An explicit add takes back the member's dismissal of the address (`wk:url:<normalized>`, the one
    /// form every client writes, §3.5.19).
    private mutating func clearDismissals(workKeys: [String]) throws {
        for target in workKeys.map({ "wk:\($0)" }) {
            let mark = try held(.mark, SyncIdentity.markID(kind: "dismissed", target: target), in: Self.libraryKey)
            if mark?.fields["on"] == .bool(true) { try writeMark("dismissed", target: target, on: false) }
        }
    }

    // MARK: - Sources in a space (§5.3 step 4, §9.4)

    /// The source an Entry of `notebook` names: in a space, the space's copy, copied in first from the
    /// learner's `Catalog` when the space lacks it; in the personal library, the learner's own.
    private mutating func sourceForFiling(_ raw: String, into notebook: Notebook) throws -> String {
        let id = resolveSourceID(raw, in: notebook)
        if try held(.source, id, in: notebook.isPersonal ? Self.catalogKey : notebook.zoneKey) != nil { return id }
        guard !notebook.isPersonal else { throw MobileRecordWriterError.refused("This source is not in your library yet. Add it on your Mac first.") }
        try copySourceIntoSpace(id, zoneKey: notebook.zoneKey)
        return id
    }

    private func resolveSourceID(_ raw: String, in notebook: Notebook) -> String {
        let zoneKey = notebook.isPersonal ? Self.catalogKey : notebook.zoneKey
        let resolved = SourceResolution.resolve(raw) { id in
            guard let source = try? held(.source, id, in: zoneKey) ?? held(.source, id, in: Self.catalogKey) else { return nil }
            return .some(source.fields["mergedInto"]?.stringValue)
        }
        return resolved
    }

    /// The learner's Source copied into a space under the same id, with no satellite: the copy asks a
    /// Mac for its files (`Job(copyFilesToSpace)`) and shows "Files arriving from your Mac" until a Mac
    /// sets its pointers. A copy starts active and carries nothing member-local (§9.3).
    private mutating func copySourceIntoSpace(_ id: String, zoneKey: String) throws {
        guard let personal = try held(.source, id, in: Self.catalogKey) else { throw MobileRecordWriterError.sourceGone }
        let fields = personal.fields
        var patch = RecordPatch(.source, id: id)
        for field in ["primaryKey", "type", "typeLocked", "title", "subtitle", "venue", "language", "authors", "url", "doi", "publishedAt",
                      "contentHash", "summary", "metrics", "madeBy", "addedAt"] {
            guard let value = fields[field], value != .null, SyncEnvelope.spilledFile(value) == nil else { continue }
            patch.changes[field] = .value(value)
        }
        let workKeys = members(fields["workKeys"])
        if !workKeys.isEmpty { patch.changes["workKeys"] = .elements(Dictionary(uniqueKeysWithValues: workKeys.map { ($0, SyncJSON.bool(true)) })) }
        if let meta = fields["meta"]?.objectValue?.filter({ $0.value != .null }), !meta.isEmpty { patch.changes["meta"] = .elements(meta) }
        patch.changes["status"] = .value(.string("active"))
        patch.changes["ingest"] = .value(.object(["ord": .array([0, 1]), "state": .string("queued"), "at": SyncJSON(milliseconds), "device": .string(deviceID)]))
        var copiedFrom: [String: SyncJSON] = ["zone": .string("personal"), "at": SyncJSON(milliseconds)]
        if let person = try person(in: zoneKey) { copiedFrom["by"] = person.value }
        patch.changes["copiedFrom"] = .value(.object(copiedFrom))
        try write(patch, in: zoneKey)
        let files = (fields["files"]?.objectValue ?? [:]).merging(fields["derived"]?.objectValue ?? [:]) { first, _ in first }
        if files.values.contains(where: { $0 != .null }), let spaceID = ProjectionZones.zone(ofKey: zoneKey).flatMap(Self.spaceID) {
            _ = try writeJob("copyFilesToSpace", target: "src:\(id)", params: .object(["spaceID": .string(spaceID)]))
        }
    }

    static func spaceID(_ zone: SyncZoneName) -> String? {
        if case .space(let id) = zone { return id }
        return nil
    }

    // MARK: - Archiving and deleting a source (§5.4)

    /// Archives a source the way the web's `removeSource` does for one with an address: it leaves every
    /// notebook and Goal of the member's (its Entries flip to `removed`) and the Schedule (its Placement
    /// flips), the member dismisses its address (so a feed does not bring it back, and a Mac's un-dismiss
    /// turns the same Mark off) and it is archived; a space's copy is archived for the space. Highlights,
    /// cards, reading state and history stay (D18).
    mutating func archiveSource(_ sourceID: String) throws {
        let zoneKey = try zoneKeys(holding: .source, sourceID).first { $0 == Self.catalogKey } ?? zoneKeys(holding: .source, sourceID).first
        guard let zoneKey, let source = try held(.source, sourceID, in: zoneKey) else { throw MobileRecordWriterError.sourceGone }
        try leaveNotebooksAndSchedule(sourceID)
        if zoneKey == Self.catalogKey, let url = source.fields["url"]?.stringValue, !url.isEmpty {
            var value: [String: SyncJSON] = ["url": .string(url)]
            if let title = source.fields["title"]?.stringValue { value["title"] = .string(title) }
            try writeMark("dismissed", target: WorkKey.dismissalTarget(url: url), on: true, value: .object(value))
        }
        var patch = RecordPatch(.source, id: sourceID)
        patch.changes["status"] = .value(.string("archived"))
        try write(patch, in: zoneKey)
    }

    /// Deletes a source of the learner's own library (§5.4): the Source record goes and the member's
    /// Placement flips to `removed`; Entries naming it are not written (they hide while it is missing and
    /// show again if it is re-imported), and its satellites are left to GC. Highlights, Cards, ReadingState,
    /// Marks, Sittings and ActivityLogs are never deleted (D18). Its explainer goes with it.
    mutating func deleteSource(_ sourceID: String, explainerID: String?) throws {
        guard try held(.source, sourceID, in: Self.catalogKey) != nil else {
            throw MobileRecordWriterError.refused("This source is only in a space. Remove it there from your Mac.")
        }
        for id in [sourceID] + (explainerID.map { [$0] } ?? []) where try held(.source, id, in: Self.catalogKey) != nil {
            try delete(.source, id, in: Self.catalogKey)
            try removePlacement(id)
        }
    }

    private mutating func leaveNotebooksAndSchedule(_ sourceID: String) throws {
        for row in try rows("""
            SELECT id FROM m_entries WHERE zone_key = ? AND item_kind = 'source' AND item_id = ? AND state = 'active'
        """, [.text(Self.libraryKey), .text(sourceID)]) {
            var patch = RecordPatch(.entry, id: row[0])
            patch.changes["state"] = .value(.string("removed"))
            try write(patch, in: Self.libraryKey)
        }
        try removePlacement(sourceID)
    }

    private mutating func removePlacement(_ sourceID: String) throws {
        let id = SyncIdentity.placementID(sourceID: sourceID)
        guard let placement = try held(.placement, id, in: Self.libraryKey), placement.fields["state"]?.stringValue != "removed" else { return }
        var patch = RecordPatch(.placement, id: id)
        patch.changes["state"] = .value(.string("removed"))
        try write(patch, in: Self.libraryKey)
    }

    /// Points the learner's own source at a walkthrough this phone wrote, its bytes uploaded first
    /// (`derived.walkthrough`, L): a later one from any device replaces it.
    mutating func pointAtWalkthrough(sourceID: String, file: FileRef) throws {
        guard try held(.source, sourceID, in: Self.catalogKey) != nil else {
            throw MobileRecordWriterError.refused("This source is not in your library yet. Add it on your Mac first.")
        }
        var patch = RecordPatch(.source, id: sourceID)
        patch.changes["derived"] = .elements(["walkthrough": file.value])
        try write(patch, in: Self.catalogKey, edited: false)
    }

    // MARK: - Helpers

    /// A set field's members: the elements whose value is `true`.
    func members(_ value: SyncJSON?) -> [String] {
        (value?.objectValue ?? [:]).compactMap { $0.value == .bool(true) ? $0.key : nil }.sorted()
    }

    /// Every row of a query, each column as text (NULL as empty).
    func rows(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [[String]] {
        var rows: [[String]] = []
        try connection.query(sql, parameters) { row in
            rows.append((0..<sqlite3_column_count(row.statement)).map { row.text($0) ?? "" })
        }
        return rows
    }

    private func zoneKeysAndIDs(of type: SyncRecordType) throws -> [(String, String)] {
        var found: [(String, String)] = []
        try connection.query("""
            SELECT zone_key, wire_id FROM ck_records WHERE record_type = ?
            UNION SELECT zone_key, wire_id FROM ck_patches WHERE record_type = ?
        """, [.text(type.rawValue), .text(type.rawValue)]) { found.append(($0.text(0) ?? "", $0.text(1) ?? "")) }
        return found
    }
}

// MARK: - The writer's operations, each one transaction

extension MobileRecordWriter {
    func createNotebook(title: String, instructions: String?, summary: String?) async throws -> String {
        try await transaction { try $0.createNotebook(title: title, instructions: instructions, summary: summary) }
    }

    func requestMoveToSpace(_ notebookID: String, to destination: MobileSpaceDestination) async throws -> String {
        try await transaction { try $0.requestMoveToSpace(notebookID, to: destination) }
    }

    func saveReadingPosition(_ sourceID: String, fraction: Double) async throws {
        try await transaction { try $0.saveReadingPosition(sourceID, fraction: fraction) }
    }

    func readingFraction(of sourceID: String) async throws -> Double? {
        try await read { try $0.readingFraction(of: sourceID) }
    }

    func recordChat(_ chat: MobileChatRecord) async throws {
        try await transaction { try $0.recordChat(chat) }
    }

    /// A captured PDF: its bytes uploaded as the source's `pdf` satellites in the private `Content`
    /// zone first, acknowledged, then the Job or the Source pointing at them (§3.5.30 rule 2, D47).
    func captureFile(at url: URL, title: String?, capture: String, target: MobileCaptureTarget?) async throws -> String {
        guard url.pathExtension.lowercased() == "pdf" else { throw MobileCloudMutationError.unsupportedCaptureFile }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sha256 = SyncIdentity.sha256Hex(bytes)
        let id = SyncIdentity.sourceFileID(sha256Hex: sha256)
        guard let blobs else { throw MobileRecordWriterError.zoneNotHeld }
        let zone = try await replica.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }
        guard let zone else { throw MobileRecordWriterError.zoneNotHeld }
        let file = try await blobs.upload(bytes, owner: id, ownerType: .source, role: "pdf", mime: "application/pdf", encoding: .identity, into: zone)
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)
        let name = clean.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        return try await transaction { try $0.captureFile(file, sha256: sha256, title: name, capture: capture, target: target) }
    }
}

extension MobileRecordWriter {
    /// A walkthrough the phone wrote, as its source's `derived.walkthrough` satellite (gzip JSON in the
    /// Mac's `PaperWalkthroughCoding`, `gen.input` the text it was made from), uploaded before the source
    /// points at it (§3.5.30 rule 2). Its pictures, if any, stay with the device that drew them.
    func saveWalkthrough(_ walkthrough: PaperWalkthrough) async throws {
        guard try await read({ try $0.held(.source, walkthrough.sourceID, in: MobileWrite.catalogKey) != nil }) else {
            throw MobileRecordWriterError.refused("This source is not in your library yet. Add it on your Mac first.")
        }
        guard let blobs,
              let zone = try await replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { throw MobileRecordWriterError.zoneNotHeld }
        let body = Data(try PaperWalkthroughCoding.json(walkthrough).utf8)
        let input: SyncJSON = .object(["input": .string(walkthrough.sourceSHA256)])
        let uploaded = try await blobs.upload(body, owner: walkthrough.sourceID, ownerType: .source, role: "walkthrough", mime: "application/json",
                                              encoding: .gzip, into: zone, gen: input)
        var object = uploaded.value.objectValue ?? [:]
        object["gen"] = input
        let file = FileRef(json: .object(object)) ?? uploaded
        try await transaction { try $0.pointAtWalkthrough(sourceID: walkthrough.sourceID, file: file) }
    }
}

// MARK: - The notebook rows, read and written as records

/// The per-member rows the phone's screens read and write by key (the chat ticks, the context
/// notebooks, the Notebook Collections, a collection's name, a notebook's naming mark): the member's
/// NotebookState and account Settings (§10, D52), read from the replica with the pending patches over
/// it and written through `MobileRecordWriter`. A key that is none of these is refused rather than
/// written anywhere.
enum MobileNotebookRows {
    /// The `[String]` rows, by key; a key with no row (or no notebook) is absent.
    static func stringArrays(_ keys: [String], writer: MobileRecordWriter) async throws -> [String: [String]] {
        try await writer.read { write in
            var rows: [String: [String]] = [:]
            for key in keys {
                let row: [String]
                if let id = suffix(key, MobileNotebookChatSelection.preferenceKeyPrefix) {
                    guard let selection = try? write.chatSelection(of: id) else { continue }
                    row = selection.excluded.sorted()
                } else if let id = suffix(key, Prefs.Families.notebookChatContextNotebooks.prefix) {
                    guard let selection = try? write.chatSelection(of: id) else { continue }
                    row = selection.contextNotebookIDs.sorted()
                } else if let id = NotebookCollections.notebookID(fromMembershipKey: key) {
                    row = try write.collections(of: id)
                } else {
                    continue
                }
                if !row.isEmpty { rows[key] = row }
            }
            return rows
        }
    }

    /// The String rows (a collection's name, a naming mark), by key.
    static func strings(_ keys: [String], writer: MobileRecordWriter) async throws -> [String: String] {
        try await writer.read { write in
            var rows: [String: String] = [:]
            for key in keys {
                if let value = try write.stringSetting(try write.settingKey(key)) { rows[key] = value }
            }
            return rows
        }
    }

    /// Writes a `[String]` row: the field becomes exactly `ids` (an empty row clears it).
    static func write(_ key: String, ids: [String], writer: MobileRecordWriter) async throws {
        try await writer.transaction { write in
            if let id = suffix(key, MobileNotebookChatSelection.preferenceKeyPrefix) {
                try write.setChatExclusions(id, to: Set(ids))
            } else if let id = suffix(key, Prefs.Families.notebookChatContextNotebooks.prefix) {
                try write.setContextNotebooks(id, to: Set(ids))
            } else if let id = NotebookCollections.notebookID(fromMembershipKey: key) {
                try write.setCollections(id, to: Set(ids))
            } else {
                throw MobileRecordWriterError.refused("\"\(key)\" is not a notebook row ForeverLM keeps.")
            }
        }
    }

    /// Writes a String row, a Setting only its own writer sets; nil clears it.
    static func write(_ key: String, string: String?, writer: MobileRecordWriter) async throws {
        try await writer.transaction { write in
            let setting = try write.settingKey(key)
            // Clearing a Setting the phone never held writes nothing.
            if string == nil, try write.stringSetting(setting) == nil { return }
            try write.writeLeftOutSetting(setting, string)
        }
    }

    private static func suffix(_ key: String, _ prefix: String) -> String? {
        guard key.hasPrefix(prefix), key.count > prefix.count else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}

/// A source's address as the phone compares it: the Core `URLNormalizer` v1 the Mac mints ids with
/// (§4.1), so the phone and its Macs read one address the same way.
enum MobileSourceURL {
    static func normalize(_ url: String) -> String {
        URLNormalizer.normalizeRemote(url) ?? url
    }
}
