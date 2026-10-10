import Foundation

// MARK: - The member's reading state, enrollments and device (docs/cloudkit-schema-design.md §10)

extension LegacyV2Mapping {
    /// A ReadingState that an old record feeds: only the fields it names, from the row values it holds.
    /// No owner; whichever old record gives one first creates it, and each gives `targetKind` and
    /// `targetID`, its required fields (§10).
    static func readingState(
        targetID: String, kind: String = "source", giving names: Set<String>, walkJSON: String? = nil, _ configure: (inout ReadingStateRow) -> Void = { _ in }
    ) -> LegacyV2Record {
        var row = ReadingStateRow(wireID: targetID)
        configure(&row)
        let encoded = ReadingStateProjection.encodeRows(ReadingStateRows(targetID: targetID, targetKind: kind, state: row, walkJSON: walkJSON, understandingDiscussed: nil))
        let fields = encoded.filter { names.contains($0.key) || $0.key == "targetKind" || $0.key == "targetID" }
        return LegacyV2Record(type: .readingState, id: SyncIdentity.readingStateID(targetID: targetID), fields: fields, giving: .creates)
    }

    /// The ReadingState an old Source gives, from the columns `deriveReadingStates` reads: the place
    /// (a PDF's page, or the reader's locator), the furthest fraction it says, the read mark and the
    /// review depth. A source with no read mark and nothing else gives a `clears` record that unsets
    /// `readAt` (a source marked unread clears it, §13.6) and makes no state (P9). A team copy gives only
    /// the read mark and the furthest, since the personal copy's place and depth come first (§10).
    static func sourceReadingState(_ payload: CloudKitSourcePayload, wireID: String, record: LegacyRecord) -> LegacyV2Record? {
        let article = payload.article
        let personal = record.teamID == nil
        let page = personal ? article.readingPositionPage : nil
        let locator = personal ? article.readingPositionLocator : nil
        let depth = personal ? payload.reviewDepth : nil
        let fraction = ReadingLocatorCodec.fraction(macLocator: article.readingPositionLocator)
        var given: Set<String> = []
        if page != nil || locator != nil { given.insert("locator") }
        if fraction != nil { given.insert("furthest") }
        // A personal copy with no read mark says it is unread: the null clears the new world's mark.
        if personal || article.readAt != nil { given.insert("readAt") }
        if depth != nil { given.insert("reviewDepth") }
        guard !given.isEmpty else { return nil }
        var state = readingState(targetID: wireID, giving: given) { row in
            if page != nil || locator != nil {
                row.position = page.map(Int64.init)
                row.locator = locator.map(ReadingLocatorCodec.wire(macLocator:))
            }
            if let fraction {
                row.furthestEpoch = 0
                row.furthest = fraction
            }
            row.readAt = article.readAt?.timeIntervalSinceReferenceDate
            row.reviewDepth = depth
        }
        // Nothing but "unread" makes no state (P9): it only clears.
        if given == ["readAt"], article.readAt == nil { state.giving = .clears }
        return state
    }

    /// The completions a notebook's items give: a source's first completion across notebooks is its
    /// `completedAt`, as `deriveReadingStates` takes the earliest. An item left uncompleted gives nothing,
    /// so it never clears one another notebook's item gave (§13.6).
    static func completionStates(_ goal: LearningGoalRecord, record: LegacyRecord, context: LegacyMappingContext) throws -> [LegacyV2Record] {
        var earliest: [String: Date] = [:]
        for item in goal.items {
            guard let completed = item.completedAt else { continue }
            let key = try context.wireID(.source, oldID: item.sourceID, teamID: record.teamID)
            earliest[key] = min(earliest[key] ?? completed, completed)
        }
        return earliest.sorted { $0.key < $1.key }.map { key, completed in
            readingState(targetID: key, giving: ["completedAt"]) { $0.completedAt = completed.timeIntervalSinceReferenceDate }
        }
    }

    /// An old WalkthroughProgress: `walk.main` of the subject's ReadingState, the whole progress object
    /// as the walk's own row keeps it. The variants other than `main` are not this record's.
    static func walkProgress(_ payload: CloudKitWalkthroughProgressPayload, context: LegacyMappingContext) throws -> LegacyV2Record? {
        let progress = payload.progress
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(progress), encoding: .utf8) else { return nil }
        let targetID = try context.sourceWireID(progress.subjectID)
        return readingState(targetID: targetID, kind: try context.readingTargetKind(targetID), giving: ["walk"], walkJSON: json)
    }

    /// A `listen.position.<sourceID>` row: the narration's resume point as `ReadingState.listen`. The
    /// `playback-position.json` beside the narration is a file, which the asset pass reads (§13.3 step 4).
    static func listenPosition(key: String, value: Any?, context: LegacyMappingContext) throws -> LegacyV2Record? {
        guard let sourceID = ListeningPositionSync.sourceID(fromPreferenceKey: key),
              let encoded = value as? String, let position = ListeningPositionSync.decode(encoded) else { return nil }
        return readingState(targetID: try context.sourceWireID(sourceID), giving: ["listen"]) { $0.listen = ListenPositionCodec.wire(position) }
    }

    // MARK: Enrollments and the device

    /// A `course.focus.<courseID>` row: the member's Enrollment with its focus, which no old-world change
    /// removes. A blank or deleted row clears the focus where an Enrollment exists, and makes none. The
    /// Enrollment's status is a creation's (`enrolled`), never one an old row resets.
    static func courseFocus(key: String, value: Any?) -> LegacyV2Record? {
        let prefix = LearnerProfile.courseFocusPreferenceKeyPrefix
        guard key.hasPrefix(prefix), key.count > prefix.count else { return nil }
        let courseID = String(key.dropFirst(prefix.count))
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return enrollmentFocus(courseID: courseID, focus: text.isEmpty ? nil : text)
    }

    static func enrollmentFocus(courseID: String, focus: String?) -> LegacyV2Record {
        var row = CourseEnrollmentRow(courseID: courseID)
        row.focus = focus
        let encoded = EnrollmentProjection.encodeRows(row)
        var fields: [String: SyncJSON] = ["courseID": encoded["courseID"] ?? .string(courseID), "focus": encoded["focus"] ?? .null]
        var record: LegacyV2Record
        if focus == nil {
            record = LegacyV2Record(type: .enrollment, id: SyncIdentity.enrollmentID(courseID: courseID), fields: fields, giving: .clears)
        } else {
            fields["status"] = encoded["status"]
            record = LegacyV2Record(type: .enrollment, id: SyncIdentity.enrollmentID(courseID: courseID), fields: fields, giving: .creates)
            record.createOnlyFields = ["status"]
        }
        return record
    }

    /// A `connectorHealth.<connector>.<field>` row: this Mac's connector health on its Device row, which the
    /// activation makes from these rows (`ensureThisDeviceRow`). The old rows hold no device, so the
    /// Mac that maps one feeds its own; with no device id yet it gives nothing. The connector's element is
    /// built from every row this Mac holds, with this row's value in it.
    static func connectorHealth(key: String, value: Any?, context: LegacyMappingContext) throws -> LegacyV2Record? {
        guard key.hasPrefix(ConnectorHealthMap.prefix), let deviceID = try context.thisDeviceID() else { return nil }
        var values = try context.connectorHealthValues()
        if let value { values[key] = value }
        let connector = key.dropFirst(ConnectorHealthMap.prefix.count).split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        guard !connector.isEmpty, let element = ConnectorHealthMap.map(values)[connector] else { return nil }
        return LegacyV2Record(
            type: .device, id: SyncIdentity.deviceRecordID(deviceID), fields: ["deviceID": .string(deviceID), "connectorHealth": .object([connector: element])],
            giving: .feeds
        )
    }
}
