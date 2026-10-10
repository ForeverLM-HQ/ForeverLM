import Foundation

// MARK: - The member's history (docs/cloudkit-schema-design.md §10: Highlight, Sitting, ActivityLog, Card state)

extension LegacyV2Mapping {
    /// An old SourceHighlight: its Highlight, on the source's wire id, from the row `saveSourceHighlightRow`
    /// writes (times in Unix seconds, a note left empty is none). No owner: per-member history, which no
    /// old-world change removes (§13.6).
    static func highlight(_ payload: CloudKitSourceHighlightPayload, context: LegacyMappingContext) throws -> LegacyV2Record {
        let highlight = payload.highlight
        let row = HighlightRow(
            id: highlight.id, sourceID: try context.sourceWireID(highlight.sourceID), pageIndex: Int64(highlight.pdfAnchor?.pageIndex ?? 0),
            geometryJSON: highlight.geometryJSON, text: highlight.quote, color: highlight.color.rawValue,
            note: highlight.note.isEmpty ? nil : highlight.note, createdAt: highlight.createdAt.timeIntervalSince1970,
            updatedAt: highlight.updatedAt.timeIntervalSince1970, anchorPrefix: highlight.anchor.prefix, anchorSuffix: highlight.anchor.suffix,
            anchorOffset: Int64(highlight.anchor.offset), chatSessionID: highlight.linkedChatID,
            referencesJSON: SourceHighlightReference.storedJSON(highlight.references),
            publicationUpdate: highlight.hasPublicationUpdate ? highlight.publicationUpdate : nil,
            publicationUpdateAt: highlight.hasPublicationUpdate ? highlight.publicationUpdateAt?.timeIntervalSince1970 : nil
        )
        return LegacyV2Record(type: .highlight, id: highlight.id, fields: HighlightProjection.encodeRows(row), giving: .creates)
    }

    /// An old MemoryAttempt: one answer in the deterministic Sitting of its chat (`session:<id>`) or its
    /// local day (`day:<YYYY-MM-DD>`), as `deriveLegacySittings` groups them, on the device `legacy22`
    /// (§4.1, §10). The Sitting is the one this Mac already holds the answer in (a group past a part's
    /// limit continues in `<id>#2`), else the group's first part; the answer is S per element.
    static func attemptSitting(_ payload: CloudKitMemoryAttemptPayload, context: LegacyMappingContext) throws -> LegacyV2Record {
        let attempt = payload.attempt
        let key = attempt.sessionID.map { "session:\($0)" } ?? "day:\(DayPlan.dateString(for: attempt.attemptedAt))"
        let id = try context.heldSittingID(answerID: attempt.id) ?? SyncIdentity.sittingLegacyID(key)
        let at = attempt.attemptedAt.timeIntervalSinceReferenceDate
        let sitting = SittingRows.Sitting(
            id: id, deviceID: SyncIdentity.legacyDeviceID, kind: attempt.sessionID == nil ? "cards" : "memoryReview", scope: nil,
            startedAt: at, endedAt: at, chatID: attempt.sessionID, part: 1, result: nil, writeUp: nil, breakMinutes: nil,
            breakEndsAt: nil, abandonedAt: nil,
            answers: [attempt.id: MemoryAnswerCodec.answer(
                for: attempt, curriculumFingerprint: try payload.parentCurriculumFingerprint ?? context.curriculumFingerprint(itemID: attempt.memoryItemID)
            )]
        )
        return LegacyV2Record(type: .sitting, id: id, fields: SittingProjection.encodeRows(.sitting(sitting)), giving: .creates)
    }

    /// A kept quiz score (`courseQuiz.score.<quizID>`, `lectureQuiz.score.<sourceID>`): the Sitting of
    /// its own, `sit:legacy:` + sha256(`quiz:<kind>:<preference key>`), its result the score with the
    /// quiz's first pass (§10).
    static func quizScoreSitting(key: String, valuePlistXML: String) -> LegacyV2Record? {
        guard let sitting = KnowledgeStore.quizScoreSitting(key: key, valuePlistXML: valuePlistXML, deviceID: SyncIdentity.legacyDeviceID) else {
            return nil
        }
        let id = SyncIdentity.sittingLegacyID("quiz:\(sitting.kind):\(key)")
        var rows = sitting
        rows.id = id
        return LegacyV2Record(type: .sitting, id: id, fields: SittingProjection.encodeRows(.sitting(rows)), giving: .creates)
    }

    // MARK: Activity

    /// A MemoryReviewActivity: the old device's review clock for a day, one element of the
    /// `legacy22` log's `reviewByDevice` (§10). A row of a generation-2 log (`al:` ids) is not an old device's.
    static func reviewActivity(_ payload: CloudKitMemoryReviewActivityPayload) -> LegacyV2Record? {
        let activity = payload.activity
        guard !activity.deviceID.hasPrefix("al:") else { return nil }
        var log = DeviceActivityLog(day: activity.day, deviceID: SyncIdentity.legacyDeviceID)
        log.reviewByDevice[activity.deviceID] = [
            "activeSeconds": .number(activity.activeSeconds), "goalSeconds": .number(activity.goalSeconds),
            "at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: activity.updatedAt.timeIntervalSinceReferenceDate)),
        ]
        return activityLog(log)
    }

    /// A ScheduledSource's activity days: one `legacy22` log per day, each source's element as
    /// `deriveLegacyActivityLogs` builds it from `source_activity_days`.
    static func sourceActivityLogs(_ days: [SourceActivityDay]) -> [LegacyV2Record] {
        func names(_ kinds: Set<SourceActivityKind>) -> [SyncJSON] {
            kinds.compactMap { DeviceActivityLog.wireKinds[$0] }.sorted().map(SyncJSON.string)
        }
        var logs: [String: DeviceActivityLog] = [:]
        for day in days.sorted(by: { ($0.dayStart, $0.sourceID) < ($1.dayStart, $1.sourceID) }) {
            let dayKey = DayPlan.dateString(for: day.dayStart)
            logs[dayKey, default: DeviceActivityLog(day: dayKey, deviceID: SyncIdentity.legacyDeviceID)].sources[day.sourceID] = [
                "kinds": .array(names(day.kinds)), "completedKinds": .array(names(day.completedKinds)), "notebookIDs": .array([]),
                "maxFraction": .number(day.maxFraction), "engagedSeconds": .number(day.engagedSeconds),
                "firstAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: day.firstActivityAt.timeIntervalSinceReferenceDate)),
                "lastAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: day.lastActivityAt.timeIntervalSinceReferenceDate)),
            ]
        }
        return logs.sorted { $0.key < $1.key }.map { activityLog($0.value) }
    }

    /// One `legacy22` log. No owner, and the old payloads repeat days already seeded, so the applier
    /// takes the maximum per (day, source) and per (day, old device), never a sum (§13.6).
    private static func activityLog(_ log: DeviceActivityLog) -> LegacyV2Record {
        LegacyV2Record(
            type: .activityLog, id: SyncIdentity.activityLogID(day: log.day, deviceID: log.deviceID),
            fields: ActivityLogProjection.encodeRows(log), giving: .creates
        )
    }

    // MARK: Card state

    /// A deck's `cards.state.<deckID>` row as its cards' states, as `mirrorCardDeckState` writes them: a
    /// kept card's state under its Memory item's id (it feeds the Card the item gives), a skipped one under
    /// `card:<deckSourceID>:<seed>` when it has a seed, else its own card id (no owner, so it creates the
    /// Card). A draft's wording is its deck Artifact's, so a draft's state is no Card yet. The variants are
    /// the row's alone, so they are given whole.
    static func cardDeckStates(key: String, valuePlistXML: String) -> [LegacyV2Record] {
        guard let deckID = MemoryCardDeckState.deckID(fromPreferenceKey: key),
              let value = PreferenceStore.decodePlist(valuePlistXML),
              let deck = MemoryCardDeckState(preferenceValue: value)
        else { return [] }
        let deckSourceID = MemoryCard.sourceID(fromDraftDeckID: deckID)
        var records: [LegacyV2Record] = []
        for (cardID, state) in deck.cards.sorted(by: { $0.key < $1.key }) where state.status != .draft {
            let kept = state.status == .kept && state.memoryItemID != nil
            let id: String
            if kept, let item = state.memoryItemID {
                id = item
            } else if let deckSourceID, let seed = state.seed {
                id = SyncIdentity.cardDraftID(deckSourceID: deckSourceID, seedKey: seed)
            } else {
                id = cardID
            }
            let at = SyncTime.milliseconds(state.updatedAt)
            var variants: [String: SyncJSON] = [:]
            for text in state.variants {
                variants[KnowledgeStore.variantKey(text)] = ["text": .string(text), "madeAt": SyncJSON(at), "retired": false]
            }
            for text in state.retiredVariants {
                variants[KnowledgeStore.variantKey(text)] = ["text": .string(text), "madeAt": SyncJSON(at), "retired": true]
            }
            if let front = state.editedFront { variants["front"] = ["text": .string(front), "madeAt": SyncJSON(at), "retired": false] }
            let rows = CardRows(item: nil, state: CardRows.State(
                status: state.status == .kept ? "kept" : state.status.rawValue, deckSourceID: deckSourceID, origin: nil, seedKey: state.seed,
                draft: nil, kept: nil, variants: variants, alwaysAsk: state.alwaysAsk, madeBy: nil, draftedAt: nil,
                skippedAt: state.status == .skipped ? state.updatedAt.timeIntervalSinceReferenceDate : nil, retiredAt: nil, supersedes: nil, splitFrom: nil
            ))
            var fields = CardProjection.encodeRows(rows)
            fields["variants"] = .object(variants)
            // A kept card's state feeds the Card its item gives: its deck, seed, variants and the way to ask it.
            if kept { fields = fields.filter { ["deckSourceID", "seedKey", "variants", "alwaysAsk"].contains($0.key) } }
            var card = LegacyV2Record(type: .card, id: id, fields: fields, giving: kept ? .feeds : .creates)
            card.wholeFields = ["variants"]
            records.append(card)
        }
        return records
    }
}

// MARK: - Teams (docs/cloudkit-schema-design.md §10, §13.7)

extension LegacyV2Mapping {
    /// An old Team: the name and the family plan code of its space's root, fed into a root that exists.
    /// The roster comes from the share, and a plan code the payload omits (a record from before schema
    /// 137) gives nothing.
    static func team(_ payload: CloudKitTeamPayload, context: LegacyMappingContext) -> LegacyV2Record {
        var fields: [String: SyncJSON] = ["name": .string(payload.name)]
        if let code = payload.familyPlanCode { fields["familyPlanCode"] = .string(code) }
        var root = LegacyV2Record(type: .zoneRoot, id: "root", fields: fields, giving: .feeds)
        root.spaceID = context.spaceID(teamID: payload.id)
        return root
    }
}
