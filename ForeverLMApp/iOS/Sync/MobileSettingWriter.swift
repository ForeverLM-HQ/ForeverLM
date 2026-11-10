import Foundation

// The phone's synced preferences (docs/cloudkit-schema-design.md §3.5.3, §10, D28). The callers
// (`MobileModelPreferenceStore`) read and write a key by its preference name; a key is what §10 makes
// of it: a key the settings catalog lists is a `Setting` record holding typed JSON (`{t, v}`), and a
// domain prefix is a field of its own record (a listening position on `ReadingState.listen`, the
// notebook rows on the member's `NotebookState`, a quiz score a `Sitting`). A value goes in and comes
// out in the property-list shape the callers use.

extension MobileSettingCatalog {
    /// What the catalog says of a key the phone writes: its value type (`SettingValue.t`), its range and
    /// the values it takes.
    struct Entry: Equatable, Sendable {
        let type: String
        var range: ClosedRange<Double>?
        var values: [String]?
    }

    /// The account keys the phone's screens set, as `schema/generated/settings-catalog.json` lists them
    /// (`MobileSettingWriterTests` holds the two together). A key outside them, and outside `families`,
    /// is refused on the phone; the Mac, the web and the hosted MCP set every other.
    static let keys: [String: Entry] = [
        AIDataPolicy.denyDataCollectionKey: Entry(type: "bool"),
        DailyReviewPreparationKeys.enabled: Entry(type: "bool"),
        MemoryReviewBudget.preferenceKey: Entry(type: "int", range: 5...120),
        TextToSpeechCostConfirmationPreferences.suppressedModelIDsKey: Entry(type: "array"),
        SourceAudioAutomation.articlesPreferenceKey: Entry(type: "bool"),
        SourceAudioAutomation.papersPreferenceKey: Entry(type: "bool"),
        SourceAudioAutomation.booksPreferenceKey: Entry(type: "bool"),
        SourceAudioAutomation.coursesPreferenceKey: Entry(type: "bool"),
        SourceAudioAutomation.explainersPreferenceKey: Entry(type: "bool"),
        ArticleSpeechSelection.syncedModelKey: Entry(type: "string"),
        ArticleSpeechSelection.syncedVoiceKey: Entry(type: "string"),
        ArticleSpeechSelection.syncedProviderKey: Entry(type: "string"),
        SharingRightsAffirmation.preferenceKey: Entry(type: "string"),
        RealtimeVoiceDefaults.voicePreferenceKey: Entry(type: "string", values: RealtimeVoiceDefaults.voices),
    ]

    /// The key families the phone writes, by prefix (a family's pattern is its prefix and a name).
    static let families: [String: Entry] = [
        ArticleSpeechVoiceRating.preferencePrefix: Entry(type: "string", values: ["up", "down"]),
        MemoryReviewDepth.typePreferenceKeyPrefix: Entry(type: "string", values: ["quick", "standard", "deep"]),
    ]

    static func entry(for key: String) -> Entry? {
        if let entry = keys[key] { return entry }
        return families.first { key.hasPrefix($0.key) && key.count > $0.key.count }?.value
    }
}

/// A Setting's value as typed JSON (§3.5.3): `{"t": <type>, "v": <value>}`, data as base64 and a date as
/// epoch milliseconds, and back into a property-list value.
enum MobileSettingValue {
    /// `value` as a Setting of `type`; nil when it is not one (a string where a number belongs).
    static func typed(_ value: Any, type: String) -> SyncJSON? {
        let inner: SyncJSON?
        switch type {
        case "bool":
            inner = (value as? Bool).map(SyncJSON.bool)
        case "int":
            guard !(value is Bool), let number = value as? NSNumber, Double(number.intValue) == number.doubleValue else { return nil }
            inner = SyncJSON(number.intValue)
        case "double":
            guard !(value is Bool), let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            inner = .number(number.doubleValue)
        case "string":
            inner = (value as? String).map(SyncJSON.string)
        case "data":
            inner = (value as? Data).map { .string($0.base64EncodedString()) }
        case "date":
            inner = (value as? Date).map { SyncJSON(SyncTime.milliseconds($0)) }
        case "array":
            inner = (value as? [Any]).flatMap(json)
        case "dict":
            inner = (value as? [String: Any]).flatMap(json)
        default:
            inner = nil
        }
        return inner.map { .object(["t": .string(type), "v": $0]) }
    }

    /// The property-list value a Setting holds; nil when it is cleared or not typed JSON.
    static func plist(_ typed: SyncJSON?) -> Any? {
        guard let typed, let type = typed["t"]?.stringValue, let value = typed["v"], value != .null else { return nil }
        switch type {
        case "bool": return value.boolValue
        case "int": return value.int64Value.map { NSNumber(value: $0) }
        case "double": return value.numberValue.map { NSNumber(value: $0) }
        case "string": return value.stringValue
        case "data": return value.stringValue.flatMap { Data(base64Encoded: $0) }
        case "date": return value.int64Value.map(SyncTime.date(milliseconds:))
        case "array", "dict": return plistValue(value)
        default: return nil
        }
    }

    private static func json(_ value: Any) -> SyncJSON? {
        switch value {
        case let bool as Bool: return .bool(bool)
        case let number as NSNumber: return number.doubleValue.isFinite ? .number(number.doubleValue) : nil
        case let string as String: return .string(string)
        case let date as Date: return SyncJSON(SyncTime.milliseconds(date))
        case let data as Data: return .string(data.base64EncodedString())
        case let array as [Any]:
            var items: [SyncJSON] = []
            for item in array {
                guard let json = json(item) else { return nil }
                items.append(json)
            }
            return .array(items)
        case let object as [String: Any]:
            var fields: [String: SyncJSON] = [:]
            for (key, item) in object {
                guard let json = json(item) else { return nil }
                fields[key] = json
            }
            return .object(fields)
        default:
            return nil
        }
    }

    private static func plistValue(_ value: SyncJSON) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let bool): return bool
        case .number(let number): return NSNumber(value: number)
        case .string(let string): return string
        case .array(let items): return items.compactMap(plistValue)
        case .object(let fields): return fields.compactMapValues(plistValue)
        }
    }
}

/// Where a preference key lives (§10): a Setting, or a field of the
/// record its domain prefix moved into.
enum MobilePreferenceRoute: Equatable, Sendable {
    /// A Setting the catalog lists (or one only its own writer sets, `leftOut`).
    case setting
    /// `listen.position.<sourceID>`: `ReadingState.listen`.
    case listenPosition(sourceID: String)
    /// A notebook's chat ticks, context notebooks or collections: `MobileNotebookRows`.
    case notebookRow
    /// `studio.pinnedNotebooks.v1`, `studio.navigation.expandedProjectIDs.v1`, `studio.projectOrder`:
    /// one NotebookState field on every notebook.
    case notebookList(field: String)
    /// `courseQuiz.score.<quizID>`, `lectureQuiz.score.<sourceID>`: the quiz's Sittings.
    case quizScore
    /// A domain prefix whose record the phone neither reads nor writes yet (`cards.state.*`, a course's
    /// focus, the Notebooks home's course order, a podcast show's block, a meeting folder's picture, a
    /// connector's health): read as absent, never written.
    case notOnPhone

    static let notebookLists: [String: String] = [
        NotebookPins.preferenceKey: "pinned",
        "studio.navigation.expandedProjectIDs.v1": "expanded",
        "studio.projectOrder": "sidebarKey",
    ]

    static let notOnPhonePrefixes = ["cards.state.", "course.focus.", "meetingFolder.image.", "connectorHealth."]
    static let notOnPhoneKeys: Set<String> = ["studio.courseOrder", "podcasts.blockedShows"]

    static func of(_ key: String) -> MobilePreferenceRoute {
        if let sourceID = ListeningPositionSync.sourceID(fromPreferenceKey: key) { return .listenPosition(sourceID: sourceID) }
        if key.hasPrefix(MobileNotebookChatSelection.preferenceKeyPrefix) || key.hasPrefix(NotebookChatContext.preferenceKeyPrefix)
            || NotebookCollections.notebookID(fromMembershipKey: key) != nil {
            return .notebookRow
        }
        if let field = notebookLists[key] { return .notebookList(field: field) }
        if key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) || key.hasPrefix(LectureQuizScore.preferenceKeyPrefix) {
            return .quizScore
        }
        if notOnPhoneKeys.contains(key) || notOnPhonePrefixes.contains(where: key.hasPrefix) { return .notOnPhone }
        return .setting
    }
}

extension MobileWrite {
    // MARK: - Reading a preference key

    /// A preference key's value as the phone holds it, as a property-list value; nil when there is none.
    func preferenceValue(_ key: String) throws -> Any? {
        switch MobilePreferenceRoute.of(key) {
        case .setting:
            return MobileSettingValue.plist(try held(.setting, try settingKey(key), in: Self.libraryKey)?.fields["value"])
        case .listenPosition(let sourceID):
            return try listenPosition(sourceID).flatMap(ListeningPositionSync.encode)
        case .notebookRow:
            return try notebookRow(key)
        case .notebookList(let field):
            let ids = try notebookList(field)
            return ids.isEmpty ? nil : ids
        case .quizScore:
            return try quizScore(key)?.preferenceValue
        case .notOnPhone:
            return nil
        }
    }

    /// The Setting a key is held under: a naming mark lives under the notebook it resolves to (§5.2).
    func settingKey(_ key: String) throws -> String {
        guard key.hasPrefix(NotebookNaming.preferenceKeyPrefix), key.count > NotebookNaming.preferenceKeyPrefix.count else { return key }
        let id = String(key.dropFirst(NotebookNaming.preferenceKeyPrefix.count))
        return NotebookNaming.preferenceKey(notebookID: (try? resolvedNotebook(id))?.id ?? id)
    }

    private func notebookRow(_ key: String) throws -> [String]? {
        let row: [String]
        if key.hasPrefix(MobileNotebookChatSelection.preferenceKeyPrefix) {
            guard let selection = try? chatSelection(of: String(key.dropFirst(MobileNotebookChatSelection.preferenceKeyPrefix.count))) else { return nil }
            row = selection.excluded.sorted()
        } else if key.hasPrefix(NotebookChatContext.preferenceKeyPrefix) {
            guard let selection = try? chatSelection(of: String(key.dropFirst(NotebookChatContext.preferenceKeyPrefix.count))) else { return nil }
            row = selection.contextNotebookIDs.sorted()
        } else if let id = NotebookCollections.notebookID(fromMembershipKey: key) {
            row = try collections(of: id)
        } else {
            return nil
        }
        return row.isEmpty ? nil : row
    }

    // MARK: - Writing a preference key

    /// Writes a preference key as what it is; nil clears it (a Setting
    /// keeps its record with `value` null, a position or a row empties). A key the phone does not set is
    /// refused, never written anywhere.
    mutating func writePreference(_ key: String, _ value: Any?) throws {
        switch MobilePreferenceRoute.of(key) {
        case .setting:
            if MobileSettingCatalog.leftOutEntry(for: key) != nil {
                let key = try settingKey(key)
                if value == nil, try stringSetting(key) == nil { return }
                guard value == nil || value is String else { throw MobileRecordWriterError.refused("\"\(key)\" takes a name.") }
                return try writeLeftOutSetting(key, value as? String)
            }
            try writeSetting(key, value)
        case .listenPosition(let sourceID):
            let position = (value as? String).flatMap(ListeningPositionSync.decode)
            guard value == nil || position != nil else { throw MobileRecordWriterError.refused("\"\(key)\" takes a listening position.") }
            try writeListenPosition(sourceID, position)
        case .notebookRow:
            guard value == nil || value is [String] else { throw MobileRecordWriterError.refused("\"\(key)\" takes a list of ids.") }
            let ids = Set(value as? [String] ?? [])
            if key.hasPrefix(MobileNotebookChatSelection.preferenceKeyPrefix) {
                try setChatExclusions(String(key.dropFirst(MobileNotebookChatSelection.preferenceKeyPrefix.count)), to: ids)
            } else if key.hasPrefix(NotebookChatContext.preferenceKeyPrefix) {
                try setContextNotebooks(String(key.dropFirst(NotebookChatContext.preferenceKeyPrefix.count)), to: ids)
            } else if let id = NotebookCollections.notebookID(fromMembershipKey: key) {
                try setCollections(id, to: ids)
            }
        case .notebookList(let field):
            guard value == nil || value is [String] else { throw MobileRecordWriterError.refused("\"\(key)\" takes a list of ids.") }
            try writeNotebookList(field, value as? [String] ?? [])
        case .quizScore:
            guard let value else { throw MobileRecordWriterError.refused("A quiz's sittings are kept; they are never cleared.") }
            guard let score = LectureQuizScore(preferenceValue: value) else { throw MobileRecordWriterError.refused("\"\(key)\" takes a quiz sitting.") }
            try recordQuizScore(score, key: key)
        case .notOnPhone:
            throw MobileRecordWriterError.refused("\"\(key)\" is set on your Mac.")
        }
    }

    /// A Setting the catalog lists, validated as `set_app_setting` validates it: a key the phone sets, a
    /// value of its type, inside its range and among its values; nil clears it (Settings are never
    /// deleted, and clearing one the phone never held writes nothing).
    mutating func writeSetting(_ key: String, _ value: Any?) throws {
        guard let entry = MobileSettingCatalog.entry(for: key) else {
            throw MobileRecordWriterError.refused("\"\(key)\" is not a setting this iPhone sets.")
        }
        let typed: SyncJSON
        if let value {
            guard let encoded = MobileSettingValue.typed(value, type: entry.type) else {
                throw MobileRecordWriterError.refused("\"\(key)\" takes a value of type \(entry.type).")
            }
            if let range = entry.range, let number = encoded["v"]?.numberValue, !range.contains(number) {
                throw MobileRecordWriterError.refused("\"\(key)\" must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
            }
            if let values = entry.values, let text = encoded["v"]?.stringValue, !values.contains(text) {
                throw MobileRecordWriterError.refused("\"\(key)\" takes one of \(values.joined(separator: ", ")).")
            }
            typed = encoded
        } else {
            guard let held = try held(.setting, key, in: Self.libraryKey)?.fields["value"], held != .null else { return }
            typed = .null
        }
        var patch = RecordPatch(.setting, id: key)
        patch.changes["key"] = .value(.string(key))
        patch.changes["value"] = .value(typed)
        patch.changes["updatedBy"] = .value(.string(deviceID))
        try write(patch, in: Self.libraryKey)
    }

    // MARK: - A listening position (§3.5.18 `listen`)

    func listenPosition(_ sourceID: String) throws -> ArticleSpeechPlaybackPosition? {
        let listen = try held(.readingState, SyncIdentity.readingStateID(targetID: sourceID), in: Self.libraryKey)?.fields["listen"]
        guard let listen, let seconds = listen["globalTime"]?.numberValue, seconds.isFinite else { return nil }
        return ArticleSpeechPlaybackPosition(
            globalTime: seconds, appleCharacterOffset: listen["appleCharacterOffset"]?.intValue,
            contentSignature: listen["contentSignature"]?.stringValue,
            updatedAt: listen["at"]?.int64Value.map(SyncTime.date(milliseconds:)) ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// The text-to-speech resume point, today's `ArticleSpeechPlaybackPosition` whole; nil clears it.
    mutating func writeListenPosition(_ sourceID: String, _ position: ArticleSpeechPlaybackPosition?) throws {
        var patch = RecordPatch(.readingState, id: SyncIdentity.readingStateID(targetID: sourceID))
        patch.changes["targetKind"] = .value(.string("source"))
        patch.changes["targetID"] = .value(.string(sourceID))
        if let position {
            var listen: [String: SyncJSON] = ["globalTime": .number(position.globalTime), "at": SyncJSON(SyncTime.milliseconds(position.updatedAt))]
            if let offset = position.appleCharacterOffset { listen["appleCharacterOffset"] = SyncJSON(offset) }
            if let signature = position.contentSignature { listen["contentSignature"] = .string(signature) }
            patch.changes["listen"] = .value(.object(listen))
        } else {
            guard try listenPosition(sourceID) != nil else { return }
            patch.changes["listen"] = .value(.null)
        }
        try write(patch, in: Self.libraryKey)
    }

    // MARK: - The notebook lists (§3.5.20 `pinned`, `expanded`, `sidebarKey`)

    /// The notebooks a list row named: the flagged ones, or for `sidebarKey` every keyed one, in the
    /// member's order (`sidebarKey`, then id), as the web reads them.
    func notebookList(_ field: String) throws -> [String] {
        var states: [(id: String, key: String?, flagged: Bool)] = []
        for id in try notebookStateIDs() {
            guard let fields = try held(.notebookState, id, in: Self.libraryKey)?.fields else { continue }
            let notebookID = fields["notebookID"]?.stringValue ?? String(id.dropFirst(3))
            let key = fields["sidebarKey"]?.stringValue.flatMap { FractionalIndex.isValid($0) ? $0 : nil }
            states.append((notebookID, key, field == "sidebarKey" ? key != nil : fields[field] == .bool(true)))
        }
        let place = Dictionary(states.compactMap { state in state.key.map { (state.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return states.filter(\.flagged).map(\.id).sorted { lhs, rhs in
            switch (place[lhs], place[rhs]) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs < rhs
            }
        }
    }

    /// Writes a list row as the web does (`writeNotebookStateList`): a flag set on the listed notebooks
    /// and cleared on those that held it; the order row gives the listed notebooks keys in its order,
    /// keeping each key that already sits in order. Only a field that changes is written.
    mutating func writeNotebookList(_ field: String, _ ids: [String]) throws {
        var listed: [String] = []
        for id in ids {
            guard let notebook = try resolvedNotebook(id), !listed.contains(notebook.id) else { continue }
            listed.append(notebook.id)
        }
        func state(_ id: String) throws -> [String: SyncJSON] {
            try held(.notebookState, SyncIdentity.notebookStateID(notebookID: id), in: Self.libraryKey)?.fields ?? [:]
        }
        guard field == "sidebarKey" else {
            let wanted = Set(listed)
            var notebooks = wanted
            for id in try notebookStateIDs() where try held(.notebookState, id, in: Self.libraryKey)?.fields[field] == .bool(true) {
                notebooks.insert(String(id.dropFirst(3)))
            }
            for id in notebooks.sorted() where (try state(id)[field] == .bool(true)) != wanted.contains(id) {
                try writeNotebookStateField(id, field, .bool(wanted.contains(id)))
            }
            return
        }
        var previous: String?
        for (position, id) in listed.enumerated() {
            let held = try state(id)["sidebarKey"]?.stringValue.flatMap { FractionalIndex.isValid($0) ? $0 : nil }
            var next: String?
            for later in listed[(position + 1)...] {
                if let key = try state(later)["sidebarKey"]?.stringValue, FractionalIndex.isValid(key) {
                    next = key
                    break
                }
            }
            let fits = held.map { key in (previous.map { key > $0 } ?? true) && (next.map { key < $0 } ?? true) } ?? false
            let key: String
            if fits, let held {
                key = held
            } else {
                let upper = next.flatMap { upper in previous.map { upper > $0 } ?? true ? upper : nil }
                key = try FractionalIndex.key(between: previous, and: upper)
            }
            if key != held { try writeNotebookStateField(id, "sidebarKey", .string(key)) }
            previous = key
        }
    }

    private mutating func writeNotebookStateField(_ notebookID: String, _ field: String, _ value: SyncJSON) throws {
        var patch = RecordPatch(.notebookState, id: SyncIdentity.notebookStateID(notebookID: notebookID))
        patch.changes["notebookID"] = .value(.string(notebookID))
        patch.changes[field] = .value(value)
        try write(patch, in: Self.libraryKey)
    }

    /// The member's NotebookState ids the phone holds (acknowledged or still a patch).
    private func notebookStateIDs() throws -> [String] {
        try rows("""
            SELECT id FROM m_notebook_states WHERE zone_key = ?
            UNION SELECT wire_id FROM ck_patches WHERE zone_key = ? AND record_type = ?
            ORDER BY 1
        """, [.text(Self.libraryKey), .text(Self.libraryKey), .text(SyncRecordType.notebookState.rawValue)]).map { $0[0] }
    }
}

extension MobileRecordWriter {
    /// A preference key's value, as `MobileWrite.preferenceValue` reads it.
    func preferenceValue(_ key: String) async throws -> Any? {
        try await read { try $0.preferenceValue(key) }
    }

    /// Several keys' values in one read; a key with no value is absent.
    func preferenceValues(_ keys: [String]) async throws -> [String: Any] {
        try await read { write in
            var values: [String: Any] = [:]
            for key in Set(keys) {
                if let value = try write.preferenceValue(key) { values[key] = value }
            }
            return values
        }
    }

    func writePreference(_ key: String, _ value: Any?) async throws {
        try await transaction { try $0.writePreference(key, value) }
    }
}
