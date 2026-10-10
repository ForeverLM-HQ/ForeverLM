import Foundation

/// The study-practice rule engine (docs/cloudkit-schema-design.md §8c, D26), Mac only. It reads the
/// learner's Sitting answers, cards and reading days, applies each rule with its minimum sample, and
/// proposes at most one `Practice` per rule, scope and period under the deterministic id
/// `pr:<ruleID>:<scope>:<period>`, so two Macs never propose one twice and a decision is never undone by
/// a later run.
///
/// It ships dark: `isEnabled` is false, so nothing runs it and nothing is shown, until the product owner signs off
/// against memory-design's "no statistics" non-goal (§15 Q1). The rules are pure (`evaluate`), so they
/// are tested without a store. Version 1 evaluates `retention-by-origin`, `new-card-load`, `time-of-day`
/// and `read-without-retrieval`; the other rules §3.5.25 names propose nothing yet.
enum PracticeEngine {
    static let isEnabled = false
    static let engineVersion = 1

    struct Answer: Equatable, Sendable {
        let cardID: String
        let at: Date
        /// nil for an answer with no grade; `again` is a miss.
        let rating: MemoryScheduleRating?
    }

    struct ReadingDay: Equatable, Sendable {
        let sourceID: String
        let day: Date
        let engagedSeconds: Double
    }

    struct Snapshot: Equatable, Sendable {
        var answers: [Answer] = []
        /// Each card's `Card.origin`.
        var cardOrigins: [String: String] = [:]
        /// The sources each card is anchored on.
        var cardSources: [String: Set<String>] = [:]
        var reading: [ReadingDay] = []
        /// The learner's daily allowance of new cards (`memory.new_cards_per_day`).
        var newCardsPerDay = MemoryCardQueue.defaultNewPerDay
    }

    /// Minimum samples: below these a rule proposes nothing (`minSampleMet` is what held).
    static let minimumAnswersPerGroup = 20
    static let minimumNewCardAnswers = 30
    static let minimumUnretrievedSources = 5
    static let readingSecondsForRetrieval: Double = 600

    /// The ISO week `now` falls in, as `Practice.period` names it (`2026-W40`).
    static func week(of now: Date, calendar: Calendar) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// The proposals for the week before `now` (the last seven days), deterministic for the same snapshot.
    static func evaluate(_ snapshot: Snapshot, now: Date, calendar: Calendar = .current) -> [PracticeRecord] {
        let start = now.addingTimeInterval(-7 * 86_400)
        let answers = snapshot.answers.filter { $0.at >= start && $0.at < now && $0.rating != nil }
        let period = week(of: now, calendar: calendar)
        let createdAt = now.timeIntervalSinceReferenceDate
        let madeBy: SyncJSON = ["engineVersion": SyncJSON(engineVersion), "at": SyncJSON(SyncTime.milliseconds(now))]

        func proposal(rule: String, title: String, body: String, evidence: [SyncJSON], ruleValue: SyncJSON?, setting: SyncJSON? = nil) -> PracticeRecord {
            PracticeRecord(
                id: SyncIdentity.practiceID(ruleID: rule, scope: "all", period: period), ruleID: rule, scope: "all", period: period,
                origin: "rule", status: "proposed", title: title, body: body, evidence: .array(evidence), minSampleMet: true,
                rule: ruleValue, settingChange: setting, madeBy: madeBy, decidedAt: nil, appliedAt: nil,
                validUntil: now.addingTimeInterval(14 * 86_400).timeIntervalSinceReferenceDate, createdAt: createdAt
            )
        }
        func retention(_ group: [Answer]) -> Double {
            Double(group.filter { $0.rating != .again }.count) / Double(max(1, group.count))
        }
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        func refs(_ group: [Answer]) -> [SyncJSON] {
            Array(Set(group.map(\.cardID))).sorted().prefix(20).map { .string("crd:" + $0) }
        }

        var proposals: [PracticeRecord] = []

        // retention-by-origin: one origin's cards remembered clearly less often than the rest.
        let byOrigin = Dictionary(grouping: answers) { snapshot.cardOrigins[$0.cardID] ?? "chat" }
            .filter { $0.value.count >= minimumAnswersPerGroup }
        if byOrigin.count >= 2 {
            let overall = retention(byOrigin.values.flatMap { $0 })
            if let (origin, group) = byOrigin.min(by: { (retention($0.value), $0.key) < (retention($1.value), $1.key) }),
               overall - retention(group) >= 0.2 {
                proposals.append(proposal(
                    rule: "retention-by-origin",
                    title: "Keep fewer \(origin) cards: you remember \(percent(retention(group))) of them, against \(percent(overall)) overall",
                    body: "Over the last seven days, \(group.count) answers to cards from \(origin) were right \(percent(retention(group))) of the time.",
                    evidence: [["kind": "retention", "refs": .array(refs(group)), "n": SyncJSON(group.count), "stat": .number(retention(group))]],
                    ruleValue: ["kind": "draftSeeds", "params": ["origin": .string(origin), "retention": .number(retention(group))]]
                ))
            }
        }

        // new-card-load: cards first answered this week are missed too often for the daily allowance.
        var firstAnswer: [String: Date] = [:]
        for answer in snapshot.answers where answer.rating != nil {
            firstAnswer[answer.cardID] = min(firstAnswer[answer.cardID] ?? answer.at, answer.at)
        }
        let newCardAnswers = answers.filter { (firstAnswer[$0.cardID] ?? .distantPast) >= start }
        if newCardAnswers.count >= minimumNewCardAnswers, snapshot.newCardsPerDay > 5 {
            let lapses = 1 - retention(newCardAnswers)
            if lapses > 0.4 {
                let value = max(5, snapshot.newCardsPerDay - 5)
                proposals.append(proposal(
                    rule: "new-card-load",
                    title: "Take \(value) new cards a day instead of \(snapshot.newCardsPerDay): \(percent(lapses)) of new cards were missed this week",
                    body: "New cards answered in the last seven days: \(newCardAnswers.count), missed: \(percent(lapses)).",
                    evidence: [["kind": "lapses", "refs": .array(refs(newCardAnswers)), "n": SyncJSON(newCardAnswers.count), "stat": .number(lapses)]],
                    ruleValue: ["kind": "newCardsPerDay", "params": ["value": SyncJSON(value)]],
                    setting: ["key": .string(MemoryCardQueue.newPerDayPreferenceKey), "value": SyncJSON(value)]
                ))
            }
        }

        // time-of-day: answers in one part of the day remembered clearly better than in another.
        func bucket(_ date: Date) -> String {
            switch calendar.component(.hour, from: date) {
            case 5..<12: return "morning"
            case 12..<18: return "afternoon"
            case 18..<24: return "evening"
            default: return "night"
            }
        }
        let byBucket = Dictionary(grouping: answers) { bucket($0.at) }.filter { $0.value.count >= minimumAnswersPerGroup }
        if byBucket.count >= 2,
           let best = byBucket.max(by: { (retention($0.value), $1.key) < (retention($1.value), $0.key) }),
           let worst = byBucket.min(by: { (retention($0.value), $0.key) < (retention($1.value), $1.key) }),
           retention(best.value) - retention(worst.value) >= 0.15 {
            proposals.append(proposal(
                rule: "time-of-day",
                title: "Review in the \(best.key): you remember \(percent(retention(best.value))) then, against \(percent(retention(worst.value))) in the \(worst.key)",
                body: "Answers in the last seven days by part of the day.",
                evidence: byBucket.keys.sorted().map { key in
                    ["kind": .string("retention." + key), "refs": .array([]), "n": SyncJSON(byBucket[key]?.count ?? 0), "stat": .number(retention(byBucket[key] ?? []))]
                },
                ruleValue: ["kind": "reviewWindow", "params": ["partOfDay": .string(best.key)]]
            ))
        }

        // read-without-retrieval: sources read at length with no card asked about them.
        let answeredSources = Set(snapshot.answers.filter { $0.at >= start }.flatMap { snapshot.cardSources[$0.cardID] ?? [] })
        let readSeconds = Dictionary(grouping: snapshot.reading.filter { $0.day >= start && $0.day < now }, by: \.sourceID)
            .mapValues { $0.reduce(0) { $0 + $1.engagedSeconds } }
        let unretrieved = readSeconds.filter { $0.value >= readingSecondsForRetrieval && !answeredSources.contains($0.key) }.keys.sorted()
        if unretrieved.count >= minimumUnretrievedSources {
            proposals.append(proposal(
                rule: "read-without-retrieval",
                title: "Recall what you read: \(unretrieved.count) sources you spent ten minutes or more on this week have no card asked yet",
                body: "Retrieval after reading keeps more than rereading; a few questions on each would do.",
                evidence: [["kind": "unretrieved", "refs": .array(unretrieved.prefix(20).map { .string("src:" + $0) }), "n": SyncJSON(unretrieved.count), "stat": .number(0)]],
                ruleValue: ["kind": "retrievalAfterReading", "params": ["minimumSeconds": SyncJSON(Int(readingSecondsForRetrieval))]]
            ))
        }
        return proposals.sorted { $0.id < $1.id }
    }
}

extension KnowledgeStore {
    /// What the rules read: the counted card answers with their cards' origins and sources, and the days
    /// sources were read, listened to or watched.
    func practiceSnapshot(newCardsPerDay: Int) throws -> PracticeEngine.Snapshot {
        var snapshot = PracticeEngine.Snapshot(newCardsPerDay: newCardsPerDay)
        try query("""
            SELECT memory_item_id, attempted_at, schedule_rating FROM memory_attempts WHERE grade_state = 'graded' ORDER BY attempted_at, id
        """, []) { row in
            guard let card = row.text(0) else { return }
            snapshot.answers.append(PracticeEngine.Answer(
                cardID: card, at: Date(timeIntervalSinceReferenceDate: row.real(1) ?? 0),
                rating: row.text(2).flatMap(MemoryScheduleRating.init(rawValue:))
            ))
        }
        var seeds: [String: String] = [:]
        try query("SELECT card_id, seed_key, origin FROM memory_card_states", []) { row in
            guard let card = row.text(0) else { return }
            if let origin = row.text(2) { snapshot.cardOrigins[card] = origin }
            if let seed = row.text(1) { seeds[card] = seed }
        }
        try query("SELECT id, kind, rubric_json FROM memory_items", []) { row in
            guard let id = row.text(0), snapshot.cardOrigins[id] == nil else { return }
            let item = MemoryItem(id: id, kind: row.text(1).flatMap(MemoryItemKind.init(rawValue:)) ?? .concept, target: "",
                                  rubricJSON: row.text(2) ?? "{}", sources: [])
            snapshot.cardOrigins[id] = CardProjection.origin(of: item, seedKey: seeds[id])
        }
        try query("SELECT memory_item_id, source_id FROM memory_item_sources", []) { row in
            if let card = row.text(0), let source = row.text(1) { snapshot.cardSources[card, default: []].insert(source) }
        }
        let timed = sourceActivityMask([.reading, .listening, .watching])
        try query("SELECT source_id, day_start, engaged_seconds FROM source_activity_days WHERE kinds & ? != 0", [.integer(timed)]) { row in
            if let source = row.text(0) {
                snapshot.reading.append(PracticeEngine.ReadingDay(
                    sourceID: source, day: Date(timeIntervalSinceReferenceDate: row.real(1) ?? 0), engagedSeconds: row.real(2) ?? 0
                ))
            }
        }
        return snapshot
    }

    /// Runs the rules at day close and proposes what they find (generation 2, and only once the engine is
    /// switched on: dark until sign-off). Returns the practices it proposed.
    @discardableResult
    func runPracticeEngine(now: Date = Date(), newCardsPerDay: Int, enabled: Bool = PracticeEngine.isEnabled) throws -> [PracticeRecord] {
        guard enabled, try recordsMemoryForGeneration2() else { return [] }
        let proposals = PracticeEngine.evaluate(try practiceSnapshot(newCardsPerDay: newCardsPerDay), now: now)
        var proposed: [PracticeRecord] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for practice in proposals where try proposePractice(practice) {
                proposed.append(practice)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return proposed
    }
}
